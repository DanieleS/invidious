{% skip_file if flag?(:api_only) %}

module Invidious::Routes::Login
  def self.login_page(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"

    referer = get_referer(env, "/feed/subscriptions")

    return env.redirect referer if user

    if !CONFIG.login_enabled
      return error_template(400, "Login has been disabled by administrator.")
    end

    email = nil
    password = nil
    captcha = nil

    account_type = env.params.query["type"]?
    account_type ||= "invidious"

    templated "user/login"
  end

  def self.login(env)
    locale = env.get("preferences").as(Preferences).locale
    host = env.get("header_x-forwarded-host")

    referer = get_referer(env, "/feed/subscriptions")

    if !CONFIG.login_enabled
      return error_template(403, "Login has been disabled by administrator.")
    end

    # The login page hides the password form under `oidc_only`, but hiding a
    # form is not disabling it: this endpoint is still reachable, and with
    # registration open it would still create local accounts.
    if CONFIG.oidc_only
      return error_template(403, "Password login has been disabled by administrator.")
    end

    # https://stackoverflow.com/a/574698
    email = env.params.body["email"]?.try &.downcase.byte_slice(0, 254)
    password = env.params.body["password"]?

    account_type = env.params.query["type"]?
    account_type ||= "invidious"

    case account_type
    when "invidious"
      if email.nil? || email.empty?
        return error_template(401, "User ID is a required field")
      end

      if password.nil? || password.empty?
        return error_template(401, "Password is a required field")
      end

      user = Invidious::Database::Users.select(email: email)

      if user
        # An account provisioned through single sign-on has no password at all,
        # and `users.password` is nullable. Without this guard `not_nil!` would
        # raise, turning a wrong login into a 500 that explains nothing.
        password_hash = user.password

        if password_hash.nil?
          return error_template(401, "Wrong username or password")
        end

        if Crypto::Bcrypt::Password.new(password_hash).verify(password.byte_slice(0, 55))
          sid = Base64.urlsafe_encode(Random::Secure.random_bytes(32))
          Invidious::Database::SessionIDs.insert(sid, email)

          if alt = CONFIG.alternative_domains.index(host)
            env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.alternative_domains[alt], sid)
          else
            env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.domain, sid)
          end
        else
          return error_template(401, "Wrong username or password")
        end

        # Since this user has already registered, we don't want to overwrite their preferences
        if env.request.cookies["PREFS"]?
          cookie = env.request.cookies["PREFS"]
          cookie.expires = Time.utc(1990, 1, 1)
          env.response.cookies << cookie
        end
      else
        if !CONFIG.registration_enabled
          return error_template(400, "Registration has been disabled by administrator.")
        end

        if password.empty?
          return error_template(401, "Password cannot be empty")
        end

        # See https://security.stackexchange.com/a/39851
        if password.bytesize > 55
          return error_template(400, "Password cannot be longer than 55 characters")
        end

        password = password.byte_slice(0, 55)

        if CONFIG.captcha_enabled
          answer = env.params.body["answer"]?

          account_type = "invidious"
          captcha = Invidious::User::Captcha.generate_image(HMAC_KEY)

          tokens = env.params.body.select { |k, _| k.match(/^token\[\d+\]$/) }.map { |_, v| v }

          if answer
            answer = answer.lstrip('0')
            answer = OpenSSL::HMAC.hexdigest(:sha256, HMAC_KEY, answer)

            begin
              validate_request(tokens[0], answer, env.request, HMAC_KEY, locale)
            rescue ex : InfoException
              return error_template(400, InfoException.new("Erroneous CAPTCHA"))
            rescue ex
              return error_template(400, ex)
            end
          else
            return templated "user/login"
          end
        end

        sid = Base64.urlsafe_encode(Random::Secure.random_bytes(32))
        user, sid = create_user(sid, email, password)

        if language_header = env.request.headers["Accept-Language"]?
          if language = ANG.language_negotiator.best(language_header, I18n::LOCALES.keys)
            user.preferences.locale = language.header
          end
        end

        Invidious::Database::Users.insert(user)
        Invidious::Database::SessionIDs.insert(sid, email)

        view_name = "subscriptions_#{sha256(user.email)}"
        PG_DB.exec("CREATE MATERIALIZED VIEW #{view_name} AS #{MATERIALIZED_VIEW_SQL.call(user.email)}")

        if alt = CONFIG.alternative_domains.index(host)
          env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.alternative_domains[alt], sid)
        else
          env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.domain, sid)
        end

        if env.request.cookies["PREFS"]?
          user.preferences = env.get("preferences").as(Preferences)
          Invidious::Database::Users.update_preferences(user)

          cookie = env.request.cookies["PREFS"]
          cookie.expires = Time.utc(1990, 1, 1)
          env.response.cookies << cookie
        end
      end

      env.redirect referer
    else
      env.redirect referer
    end
  end

  # Single sign-on, step 1: start the authorization code flow and park in a
  # cookie the values the callback will need to finish it.
  def self.oidc_login(env)
    locale = env.get("preferences").as(Preferences).locale

    referer = get_referer(env, "/feed/subscriptions")

    # Deliberately no "already signed in, go back where you came from"
    # shortcut here, unlike `login_page`. A browser holding a session cookie
    # that is *not* valid site-wide would be bounced away from the one endpoint
    # able to give it a good one, with nothing said about why — and starting a
    # flow is idempotent anyway: the provider still has its session and hands
    # back the same account.

    if !CONFIG.login_enabled
      return error_template(400, "Login has been disabled by administrator.")
    end

    if !Invidious::OIDC.enabled?
      return error_template(404, "Single sign-on has not been configured.")
    end

    # A session cookie scoped to "/oidc" is a leftover from the defect fixed in
    # #6: it reaches these endpoints and nowhere else, so Invidious sees a
    # signed-in visitor here while every other page sees an anonymous one. Left
    # alone it puts such a browser in a loop between /login and /oidc/login.
    # Clearing it is one header, and it heals itself on the next attempt.
    env.response.cookies << HTTP::Cookie.new(
      name: "SID",
      value: "",
      path: "/oidc",
      expires: Time.utc(1990, 1, 1),
      http_only: true,
      samesite: HTTP::Cookie::SameSite::Lax
    )

    state = Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
    nonce = Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
    code_verifier = Invidious::OIDC.generate_code_verifier

    begin
      authorization_url = Invidious::OIDC.authorization_url(
        redirect_uri: self.oidc_redirect_uri,
        state: state,
        nonce: nonce,
        code_challenge: Invidious::OIDC.code_challenge_for(code_verifier)
      )
    rescue ex : Invidious::OIDC::Error
      LOGGER.error(ex.message.to_s)
      return error_template(503, "The identity provider could not be reached.")
    end

    flow = {state: state, nonce: nonce, code_verifier: code_verifier, referer: referer}
    env.response.cookies << self.oidc_flow_cookie(flow.to_json)

    env.redirect authorization_url
  end

  # Single sign-on, step 2: the provider sends the browser back here.
  def self.oidc_callback(env)
    locale = env.get("preferences").as(Preferences).locale
    host = env.get("header_x-forwarded-host")

    if !CONFIG.login_enabled || !Invidious::OIDC.enabled?
      return error_template(400, "Login has been disabled by administrator.")
    end

    flow_cookie = env.request.cookies[OIDC_FLOW_COOKIE]?

    # A flow cookie is good for exactly one callback, whatever the outcome.
    env.response.cookies << self.oidc_flow_cookie("", expired: true)

    if flow_cookie.nil?
      return error_template(400, "This sign-on attempt has expired. Please try again.")
    end

    begin
      flow = JSON.parse(URI.decode_www_form(flow_cookie.value))
      state = flow["state"].as_s
      nonce = flow["nonce"].as_s
      code_verifier = flow["code_verifier"].as_s
      # Already sanitised into a local path by `get_referer` in step 1.
      referer = flow["referer"].as_s
    rescue
      return error_template(400, "This sign-on attempt has expired. Please try again.")
    end

    # The provider cannot set cookies for this host, so a `state` matching the
    # cookie is what proves this callback answers a flow that this browser
    # started. Without it the callback is a CSRF hole — the defect review found
    # in iv-org/invidious#3164.
    if env.params.query["state"]? != state
      return error_template(400, "This sign-on attempt could not be verified. Please try again.")
    end

    if error = env.params.query["error"]?
      LOGGER.error("OIDC: provider refused the login: #{error}")
      return error_template(403, "The identity provider refused the sign-on.")
    end

    code = env.params.query["code"]?
    if code.nil? || code.empty?
      return error_template(400, "The identity provider returned no authorization code.")
    end

    begin
      tokens = Invidious::OIDC.exchange_code(code, code_verifier, self.oidc_redirect_uri)
      claims = Invidious::OIDC.claims(tokens, nonce)
    rescue ex : Invidious::OIDC::Error
      LOGGER.error(ex.message.to_s)
      return error_template(403, "The identity provider refused the sign-on.")
    end

    email = Invidious::OIDC.identity(claims)
    if email.nil?
      LOGGER.error("OIDC: claim '#{CONFIG.oidc_claim}' is missing from the token")
      return error_template(403, "The identity provider returned no account identity.")
    end

    user = Invidious::Database::Users.select(email: email)
    sid = Base64.urlsafe_encode(Random::Secure.random_bytes(32))

    if user.nil?
      if !CONFIG.oidc_auto_provision
        return error_template(403, "This account does not exist and automatic account creation is disabled.")
      end

      # No password: `users.password` is nullable, and an account with none can
      # only ever be entered through the provider.
      user, sid = create_user(sid, email, nil)

      if language_header = env.request.headers["Accept-Language"]?
        if language = ANG.language_negotiator.best(language_header, I18n::LOCALES.keys)
          user.preferences.locale = language.header
        end
      end

      Invidious::Database::Users.insert(user)

      # The subscriptions feed reads a materialized view per user that nothing
      # creates on demand: registration builds it by hand, and so must this
      # path, or subscriptions are broken for every account created here.
      view_name = "subscriptions_#{sha256(user.email)}"
      PG_DB.exec("CREATE MATERIALIZED VIEW #{view_name} AS #{MATERIALIZED_VIEW_SQL.call(user.email)}")

      # Preferences the visitor set while anonymous are worth keeping on the
      # account that has just been created for them, exactly as registration
      # does.
      if env.request.cookies["PREFS"]?
        user.preferences = env.get("preferences").as(Preferences)
        Invidious::Database::Users.update_preferences(user)
      end
    end

    Invidious::Database::SessionIDs.insert(sid, email)

    if alt = CONFIG.alternative_domains.index(host)
      env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.alternative_domains[alt], sid)
    else
      env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.domain, sid)
    end

    # Preferences in a cookie belong to the anonymous visitor and would shadow
    # the ones stored on the account.
    if env.request.cookies["PREFS"]?
      cookie = env.request.cookies["PREFS"]
      cookie.expires = Time.utc(1990, 1, 1)
      env.response.cookies << cookie
    end

    env.redirect referer
  end

  OIDC_FLOW_COOKIE = "OIDC_FLOW"

  # Holds `state`, `nonce`, the PKCE verifier and where to return to.
  #
  # SameSite has to be Lax and not Strict: the callback arrives as a top-level
  # navigation from the provider's site, and Strict withholds the cookie in
  # exactly that case, which would break every sign-on. No domain is set
  # either, so the cookie stays bound to the host that issued it.
  private def self.oidc_flow_cookie(value : String, expired : Bool = false) : HTTP::Cookie
    HTTP::Cookie.new(
      name: OIDC_FLOW_COOKIE,
      value: URI.encode_www_form(value),
      path: "/",
      expires: expired ? Time.utc(1990, 1, 1) : Time.utc + 10.minutes,
      secure: (Kemal.config.ssl || CONFIG.https_only) ? true : false,
      http_only: true,
      samesite: HTTP::Cookie::SameSite::Lax
    )
  end

  # Built from the configured domain rather than from the request, because the
  # redirect URI sent to the authorization endpoint and the one sent to the
  # token endpoint have to be byte-identical: providers compare them and reject
  # the exchange when they differ.
  private def self.oidc_redirect_uri : String
    "#{HOST_URL}/oidc/callback"
  end

  def self.signout(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env)

    if !user
      return env.redirect referer
    end

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      return error_template(400, ex)
    end

    Invidious::Database::SessionIDs.delete(sid: sid)

    env.request.cookies.each do |cookie|
      cookie.expires = Time.utc(1990, 1, 1)
      env.response.cookies << cookie
    end

    # An account with no password can only have been created by single sign-on.
    # Ending just the Invidious session would leave the provider's own session
    # standing, so the next click on "log in" would walk straight back in
    # without asking anything — which does not look like a sign-out.
    if CONFIG.oidc_rp_logout && Invidious::OIDC.enabled? && user.password.nil?
      if end_session_url = Invidious::OIDC.end_session_url(HOST_URL.presence)
        return env.redirect end_session_url
      end
    end

    env.redirect referer
  end
end
