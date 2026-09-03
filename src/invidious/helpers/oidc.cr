require "digest/sha256"
require "json"
require "uri"

# OpenID Connect single sign-on.
#
# This implements *only* the authorization code flow with PKCE against a
# confidential client, and reads the claims from the ID token exactly as the
# token endpoint returned it. That restriction is what keeps this file free of
# new dependencies: Crystal's standard library cannot verify an RS256
# signature (it does not expose `OpenSSL::PKey::RSA`, see
# crystal-lang/crystal#3941), so validating a JWKS signature would mean adding
# `crystal-community/jwt` and its three transitive shards to a project that has
# six in total — and then validating their LibCrypto bindings against the
# OpenSSL that `docker/Dockerfile` builds from source and links statically.
#
# Skipping the signature check is sound *here and nowhere else*: OpenID Connect
# Core §3.1.3.7 rule 6 allows it when the ID token is received directly from
# the token endpoint over a TLS-authenticated channel, which is the case below
# — the token never passes through the browser. The moment a front-channel flow
# (implicit or hybrid) is added, this stops being true and full JWKS validation
# becomes mandatory. Hence: no `response_type` other than `code`, ever.
#
# What *is* verified: the `state` (in the route, against a cookie the provider
# cannot write), and the ID token's `iss`, `aud`, `exp` and `nonce`.
module Invidious::OIDC
  extend self

  class Error < Exception
  end

  struct Endpoints
    include JSON::Serializable

    # Taken from the discovery document rather than from the config, so that
    # the `iss` check below compares against what the provider says about
    # itself.
    getter issuer : String
    getter authorization_endpoint : String
    getter token_endpoint : String
    getter userinfo_endpoint : String? = nil
    getter end_session_endpoint : String? = nil
    getter token_endpoint_auth_methods_supported : Array(String) = ["client_secret_basic"]
  end

  @@endpoints : Endpoints? = nil
  @@mutex = Mutex.new

  def enabled? : Bool
    !CONFIG.oidc_issuer.empty?
  end

  # Endpoints are discovered lazily and then cached for the lifetime of the
  # process. Lazily on purpose: discovering at boot would make Invidious
  # unable to start whenever the identity provider is down, which for a
  # self-hosted pair of services means a boot order dependency nobody asked
  # for. This way a provider that is down only breaks logging in.
  def endpoints : Endpoints
    if cached = @@endpoints
      return cached
    end

    @@mutex.synchronize do
      # Another fiber may have discovered while this one waited on the lock.
      if cached = @@endpoints
        return cached
      end

      discovered = discover
      @@endpoints = discovered
      return discovered
    end
  end

  private def discover : Endpoints
    issuer = CONFIG.oidc_issuer.rstrip('/')
    url = URI.parse("#{issuer}/.well-known/openid-configuration")

    body = get(url)
    endpoints = Endpoints.from_json(body)

    # A provider whose advertised issuer differs from the configured one means
    # the config points at the wrong place; every `iss` check afterwards would
    # fail with a far less obvious message.
    if endpoints.issuer.rstrip('/') != issuer
      raise Error.new("OIDC: provider advertises issuer '#{endpoints.issuer}', configured '#{issuer}'")
    end

    LOGGER.info("OIDC: discovered endpoints for #{endpoints.issuer}")
    endpoints
  rescue ex : JSON::ParseException | JSON::SerializableError
    raise Error.new("OIDC: discovery document at #{CONFIG.oidc_issuer} is not valid: #{ex.message}")
  end

  # `openid` is what makes this OpenID Connect rather than plain OAuth 2, and
  # without it a provider is free to return no ID token at all. It is added
  # here instead of being required in the config so that a missing scope is not
  # a footgun.
  def scopes : Array(String)
    scopes = CONFIG.oidc_scopes.dup
    scopes.unshift("openid") if !scopes.includes?("openid")
    scopes
  end

  def authorization_url(redirect_uri : String, state : String, nonce : String, code_challenge : String) : String
    params = URI::Params.build do |form|
      form.add "response_type", "code"
      form.add "client_id", CONFIG.oidc_client_id
      form.add "redirect_uri", redirect_uri
      form.add "scope", scopes.join(' ')
      form.add "state", state
      form.add "nonce", nonce
      form.add "code_challenge", code_challenge
      form.add "code_challenge_method", "S256"
    end

    url = URI.parse(endpoints.authorization_endpoint)

    # A provider is allowed to put query parameters in its own authorization
    # endpoint; appending would otherwise produce a second '?'.
    existing = url.query
    url.query = existing.nil? || existing.empty? ? params : "#{existing}&#{params}"
    url.to_s
  end

  # PKCE (RFC 7636). The verifier is what the token endpoint checks against the
  # challenge sent earlier, so an intercepted authorization code is useless
  # without the cookie holding the verifier.
  def generate_code_verifier : String
    Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
  end

  def code_challenge_for(code_verifier : String) : String
    Base64.urlsafe_encode(Digest::SHA256.digest(code_verifier), padding: false)
  end

  def exchange_code(code : String, code_verifier : String, redirect_uri : String) : JSON::Any
    url = URI.parse(endpoints.token_endpoint)

    body = URI::Params.build do |form|
      form.add "grant_type", "authorization_code"
      form.add "code", code
      form.add "redirect_uri", redirect_uri
      form.add "code_verifier", code_verifier
      # Sent in the body only when the provider does not accept HTTP Basic.
      if !basic_auth?
        form.add "client_id", CONFIG.oidc_client_id
        form.add "client_secret", CONFIG.oidc_client_secret
      end
    end

    headers = HTTP::Headers{
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }

    if basic_auth?
      credentials = Base64.strict_encode("#{URI.encode_www_form(CONFIG.oidc_client_id)}:#{URI.encode_www_form(CONFIG.oidc_client_secret)}")
      headers["Authorization"] = "Basic #{credentials}"
    end

    response = make_client(url, use_http_proxy: false, &.post(url.request_target, headers: headers, form: body))

    if !response.status.success?
      # The body carries the provider's `error` / `error_description`, which is
      # the only thing that ever explains a failed exchange. It cannot contain
      # the code (already spent) nor the secret.
      raise Error.new("OIDC: token endpoint returned #{response.status_code}: #{response.body.byte_slice(0, 512)}")
    end

    JSON.parse(response.body)
  rescue ex : JSON::ParseException
    raise Error.new("OIDC: token endpoint returned a body that is not JSON")
  end

  private def basic_auth? : Bool
    endpoints.token_endpoint_auth_methods_supported.includes?("client_secret_basic")
  end

  # Claims of the ID token, after the checks that are still meaningful without
  # a signature: who issued it, who it is for, whether it expired, and whether
  # it belongs to *this* login attempt (`nonce`).
  def claims(token_response : JSON::Any, nonce : String) : Hash(String, JSON::Any)
    id_token = token_response["id_token"]?.try &.as_s?
    raise Error.new("OIDC: no id_token in the token endpoint response") if id_token.nil?

    segments = id_token.split('.')
    raise Error.new("OIDC: id_token is not a JWT") if segments.size < 2

    payload = JSON.parse(decode_segment(segments[1])).as_h

    issuer = payload["iss"]?.try &.as_s?
    if issuer.nil? || issuer.rstrip('/') != endpoints.issuer.rstrip('/')
      raise Error.new("OIDC: id_token issued by '#{issuer}', expected '#{endpoints.issuer}'")
    end

    # `aud` is a string or an array of strings, and may legitimately contain
    # other audiences besides this client.
    audiences = case audience = payload["aud"]?
                in Nil       then [] of String
                in JSON::Any then audience.as_s? ? [audience.as_s] : (audience.as_a? || [] of JSON::Any).compact_map(&.as_s?)
                end

    if !audiences.includes?(CONFIG.oidc_client_id)
      raise Error.new("OIDC: id_token is not addressed to this client")
    end

    expires = payload["exp"]?.try &.as_i64?
    if expires.nil? || Time.unix(expires) < Time.utc
      raise Error.new("OIDC: id_token has expired")
    end

    # Without this, an ID token captured from another login of the same user
    # could be replayed into this one.
    if payload["nonce"]?.try &.as_s? != nonce
      raise Error.new("OIDC: id_token nonce does not match this login attempt")
    end

    # Some providers keep the email out of the ID token and only serve it from
    # userinfo. Asking for it is cheap and happens once per login.
    if !payload.has_key?(CONFIG.oidc_claim)
      if access_token = token_response["access_token"]?.try &.as_s?
        payload.merge!(userinfo(access_token))
      end
    end

    payload
  rescue ex : JSON::ParseException | Base64::Error
    raise Error.new("OIDC: id_token payload could not be decoded")
  end

  private def userinfo(access_token : String) : Hash(String, JSON::Any)
    endpoint = endpoints.userinfo_endpoint
    return {} of String => JSON::Any if endpoint.nil?

    url = URI.parse(endpoint)
    headers = HTTP::Headers{"Authorization" => "Bearer #{access_token}", "Accept" => "application/json"}
    response = make_client(url, use_http_proxy: false, &.get(url.request_target, headers: headers))

    if !response.status.success?
      LOGGER.error("OIDC: userinfo returned #{response.status_code}")
      return {} of String => JSON::Any
    end

    JSON.parse(response.body).as_h
  rescue ex
    LOGGER.error("OIDC: userinfo could not be read: #{ex.message}")
    {} of String => JSON::Any
  end

  # The claim carrying the identity. It is matched against `users.email`, which
  # is Invidious' primary key for an account and already carries a unique
  # index.
  def identity(claims : Hash(String, JSON::Any)) : String?
    identity = claims[CONFIG.oidc_claim]?.try &.as_s?
    return nil if identity.nil? || identity.empty?

    # Same normalisation the password login applies, so that the two paths
    # cannot end up with two rows for one person.
    identity.downcase.byte_slice(0, 254)
  end

  # RP-initiated logout (OpenID Connect RP-Initiated Logout 1.0). Returns nil
  # when the provider does not advertise the endpoint, in which case signing
  # out stays local to Invidious.
  def end_session_url(post_logout_redirect_uri : String?) : String?
    endpoint = endpoints.end_session_endpoint
    return nil if endpoint.nil?

    params = URI::Params.build do |form|
      form.add "client_id", CONFIG.oidc_client_id
      form.add "post_logout_redirect_uri", post_logout_redirect_uri if post_logout_redirect_uri
    end

    url = URI.parse(endpoint)
    existing = url.query
    url.query = existing.nil? || existing.empty? ? params : "#{existing}&#{params}"
    url.to_s
  rescue ex : Error
    # Signing out must never fail because discovery did.
    LOGGER.error("OIDC: #{ex.message}")
    nil
  end

  private def get(url : URI) : String
    response = make_client(url, use_http_proxy: false, &.get(url.request_target, headers: HTTP::Headers{"Accept" => "application/json"}))

    if !response.status.success?
      raise Error.new("OIDC: GET #{url} returned #{response.status_code}")
    end

    response.body
  rescue ex : IO::Error | Socket::Error
    raise Error.new("OIDC: #{url.host} is unreachable: #{ex.message}")
  end

  # JWT segments are base64url without padding.
  private def decode_segment(segment : String) : String
    padding = (4 - segment.bytesize % 4) % 4
    Base64.decode_string(segment.tr("-_", "+/") + ("=" * padding))
  end
end
