module HTTP::Handler
  @@exclude_routes_tree = Radix::Tree(String).new

  macro exclude(paths, method = "GET")
      class_name = {{@type.name}}
      method_downcase = {{method.downcase}}
      class_name_method = "#{class_name}/#{method_downcase}"
      ({{paths}}).each do |path|
        @@exclude_routes_tree.add class_name_method + path, '/' + method_downcase + path
      end
    end

  def exclude_match?(env : HTTP::Server::Context)
    @@exclude_routes_tree.find(radix_path(env.request.method, env.request.path)).found?
  end

  private def radix_path(method : String, path : String)
    "#{self.class}/#{method.downcase}#{path}"
  end
end

class Kemal::RouteHandler
  {% for method in %w(GET POST PUT HEAD DELETE PATCH OPTIONS) %}
    exclude ["/api/v1/*"], {{method}}
  {% end %}

  # Processes the route if it's a match. Otherwise renders 404.
  private def process_request(context)
    raise Kemal::Exceptions::RouteNotFound.new(context) unless context.route_found?
    return if context.response.closed?
    content = context.route.handler.call(context)

    if !Kemal.config.error_handlers.empty? && Kemal.config.error_handlers.has_key?(context.response.status_code) && exclude_match?(context)
      raise Kemal::Exceptions::CustomException.new(context)
    end

    if context.request.method == "HEAD" && context.request.path.ends_with? ".jpg"
      context.response.headers["Content-Type"] = "image/jpeg"
    end

    context.response.print(content)
    context
  end
end

class Kemal::ExceptionHandler
  {% for method in %w(GET POST PUT HEAD DELETE PATCH OPTIONS) %}
    exclude ["/api/v1/*"], {{method}}
  {% end %}

  private def call_exception_with_status_code(context : HTTP::Server::Context, exception : Exception, status_code : Int32)
    return if context.response.closed?
    return if exclude_match? context

    if !Kemal.config.error_handlers.empty? && Kemal.config.error_handlers.has_key?(status_code)
      context.response.content_type = "text/html" unless context.response.headers.has_key?("Content-Type")
      context.response.status_code = status_code
      context.response.print Kemal.config.error_handlers[status_code].call(context, exception)
      context
    end
  end
end

class FilteredCompressHandler < HTTP::CompressHandler
  exclude ["/videoplayback", "/videoplayback/*", "/vi/*", "/sb/*", "/ggpht/*", "/api/v1/auth/notifications"]
  exclude ["/api/v1/auth/notifications", "/data_control"], "POST"

  def call(context)
    return call_next context if exclude_match? context
    super
  end
end

class AuthHandler < Kemal::Handler
  {% for method in %w(GET POST PUT HEAD DELETE PATCH OPTIONS) %}
    only ["/api/v1/auth/*"], {{method}}
  {% end %}

  def call(env)
    return call_next env unless only_match? env

    begin
      if token = env.request.headers["Authorization"]?
        token = JSON.parse(URI.decode_www_form(token.lchop("Bearer ")))
        session = URI.decode_www_form(token["session"].as_s)
        scopes, _, _ = validate_request(token, session, env.request, HMAC_KEY, nil)

        if email = Invidious::Database::SessionIDs.select_email(session)
          user = Invidious::Database::Users.select!(email: email)
        end
      elsif sid = env.request.cookies["SID"]?.try &.value
        if sid.starts_with? "v1:"
          raise "Cannot use token as SID"
        end

        if email = Invidious::Database::SessionIDs.select_email(sid)
          user = Invidious::Database::Users.select!(email: email)
        end

        scopes = [":*"]
        session = sid
      end

      if !user
        raise "Request must be authenticated"
      end

      env.set "scopes", scopes
      env.set "user", user
      env.set "session", session

      call_next env
    rescue ex
      env.response.content_type = "application/json"

      error_message = {"error" => ex.message}.to_json
      env.response.status_code = 403
      env.response.print error_message
    end
  end
end

class APIHandler < Kemal::Handler
  {% for method in %w(GET POST PUT HEAD DELETE PATCH OPTIONS) %}
  only ["/api/v1/*"], {{method}}
  {% end %}
  exclude ["/api/v1/auth/notifications"], "GET"
  exclude ["/api/v1/auth/notifications"], "POST"

  def call(env)
    env.response.headers["Access-Control-Allow-Origin"] = "*" if only_match?(env)
    call_next env
  end
end

class DisableAbusableAPIHandler < Kemal::Handler
  {% for method in %w(GET HEAD) %}
    # This endpoints make a video request to Invidious companion.
    {% for endpoint in %w(videos clips transcripts) %}
      only ["/api/v1/{{ endpoint.id }}/:id"], {{ method }}
    {% end %}
  {% end %}

  def call(env)
    return call_next env unless only_match?(env) && CONFIG.disable_abusable_api

    env.response.content_type = "application/json"
    env.response.status_code = 403
    message = {"error" => "This API endpoint has been disabled by the administrator."}.to_json
    env.response.print message
    env.response.close
    return
  end
end

class DenyFrame < Kemal::Handler
  exclude ["/embed/*"]

  def call(env)
    return call_next env if exclude_match? env

    env.response.headers["X-Frame-Options"] = "sameorigin"
    call_next env
  end
end

# Serves nothing to visitors without a session when `private_instance` is on,
# so that an instance meant for one household does not hand pages to whoever
# finds the domain.
#
# This is a handler and not a `before_all` filter because a Kemal filter cannot
# stop a route from running: `Kemal::FilterHandler` skips `call_next` only when
# the status code left behind matches a registered error handler, so a redirect
# written in a filter would be followed by the route writing its own body over
# the top of it.
class PrivateInstanceHandler < Kemal::Handler
  # What stays reachable without a session, and why:
  #
  #   - the login endpoints, or there would be no way in at all;
  #   - the assets the login page itself loads;
  #   - the media proxy paths, which `Routes::BeforeAll` skips as well. Gating
  #     them would mean a session lookup for every thumbnail and every chunk of
  #     video. The trade-off is that whoever already holds one of those URLs can
  #     still fetch that media: they are signed or carry a video id, and they
  #     expose no page, no account and no way to browse.
  #   - the feeds that carry a token of their own, which is how a feed reader
  #     subscribes without a cookie.
  PUBLIC_PREFIXES = {
    "/login", "/oidc/", "/signout",
    "/css/", "/js/", "/fonts/", "/assets/",
    "/sb/", "/vi/", "/s_p/", "/yts/", "/ggpht/",
    "/api/manifest/", "/videoplayback", "/latest_version", "/download", "/companion/",
    "/feed/private", "/feed/playlist/", "/feed/webhook/",
  }

  PUBLIC_PATHS = {
    "/favicon.ico", "/robots.txt", "/site.webmanifest", "/manifest.json", "/opensearch.xml",
  }

  def call(env)
    return call_next env if !CONFIG.private_instance

    path = env.request.path
    return call_next env if PUBLIC_PATHS.includes?(path)
    return call_next env if PUBLIC_PREFIXES.any? { |prefix| path.starts_with?(prefix) }
    return call_next env if authenticated?(env)

    # An API client has nowhere to follow a redirect to.
    if path.starts_with?("/api/")
      env.response.content_type = "application/json"
      env.response.status_code = 401
      env.response.print({"error" => "This instance is private. Please log in."}.to_json)
      env.response.close
      return
    end

    env.redirect "/login?referer=#{URI.encode_www_form(env.request.resource)}"
    env.response.close
  end

  private def authenticated?(env) : Bool
    # `AuthHandler` runs earlier and has already resolved the API token routes.
    return true if env.get?("user")

    sid = env.request.cookies["SID"]?.try &.value
    return false if sid.nil? || sid.empty?

    # A "v1:" value is an API token rather than a session, and is only ever
    # valid on the routes `AuthHandler` covers.
    return false if sid.starts_with?("v1:")

    !Invidious::Database::SessionIDs.select_email(sid).nil?
  end
end
