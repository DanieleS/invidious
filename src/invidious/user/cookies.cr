require "http/cookie"

struct Invidious::User
  module Cookies
    extend self

    # Note: we use ternary operator because the two variables
    # used in here are not booleans.
    @@secure = (Kemal.config.ssl || CONFIG.https_only) ? true : false

    # Session ID (SID) cookie
    # Parameter "domain" comes from the global config
    def sid(domain : String?, sid) : HTTP::Cookie
      # Not secure if it's being accessed from I2P
      # Browsers expect the domain to include https. On I2P there is no HTTPS
      # Tor browser works fine with secure being true
      if (domain.try &.split(".").last == "i2p") && @@secure
        @@secure = false
      end

      return HTTP::Cookie.new(
        name: "SID",
        domain: domain,
        # Without an explicit path, RFC 6265 §5.1.4 has the browser derive the
        # cookie's default path from the *directory* of the request that set
        # it. Set from "/login" that happens to be "/", which is why this was
        # never noticed; set from "/oidc/callback" it becomes "/oidc", and the
        # session cookie is then sent only back to the login endpoints — the
        # user appears logged out everywhere else, with no error anywhere.
        path: "/",
        value: sid,
        expires: Time.utc + 2.years,
        secure: @@secure,
        http_only: true,
        samesite: HTTP::Cookie::SameSite::Lax
      )
    end

    # Preferences (PREFS) cookie
    # Parameter "domain" comes from the global config
    def prefs(domain : String?, preferences : Preferences) : HTTP::Cookie
      # Not secure if it's being accessed from I2P
      # Browsers expect the domain to include https. On I2P there is no HTTPS
      # Tor browser works fine with secure being true
      if (domain.try &.split(".").last == "i2p") && @@secure
        @@secure = false
      end

      return HTTP::Cookie.new(
        name: "PREFS",
        domain: domain,
        value: URI.encode_www_form(preferences.to_json),
        expires: Time.utc + 2.years,
        secure: @@secure,
        http_only: false,
        samesite: HTTP::Cookie::SameSite::Lax
      )
    end
  end
end
