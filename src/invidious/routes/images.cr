module Invidious::Routes::Images
  # Avatars, banners and other large image assets.
  def self.ggpht(env)
    url = env.request.path.lchop("/ggpht")

    headers = HTTP::Headers.new

    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      GGPHT_POOL.client &.get(url, headers) do |resp|
        return self.proxy_image(env, resp)
      end
    rescue ex
    end
  end

  def self.options_storyboard(env)
    env.response.headers["Access-Control-Allow-Origin"] = "*"
    env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
  end

  def self.get_storyboard(env)
    authority = env.params.url["authority"]
    id = env.params.url["id"]
    storyboard = env.params.url["storyboard"]
    index = env.params.url["index"]

    url = "/sb/#{id}/#{storyboard}/#{index}?#{env.params.query}"

    headers = HTTP::Headers.new

    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      get_ytimg_pool(authority).client &.get(url, headers) do |resp|
        env.response.headers["Connection"] = "close"
        return self.proxy_image(env, resp)
      end
    rescue ex
    end
  end

  # ??? maybe also for storyboards?
  def self.s_p_image(env, authority = "i9")
    id = env.params.url["id"]
    name = env.params.url["name"]
    url = env.request.resource

    headers = HTTP::Headers.new

    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      get_ytimg_pool(authority).client &.get(url, headers) do |resp|
        return self.proxy_image(env, resp)
      end
    rescue ex
    end
  end

  # Both pl_c and tvfilm_banner use the same logic used in s_p_image(env)
  # just with a different authority ("i").
  def self.pl_c_image(env)
    self.s_p_image(env, "i")
  end

  def self.tvfilm_banner_image(env)
    self.s_p_image(env, "i")
  end

  def self.yts_image(env)
    headers = HTTP::Headers.new
    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      YT_POOL.client &.get(env.request.resource, headers) do |response|
        env.response.status_code = response.status_code
        response.headers.each do |key, value|
          if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
            env.response.headers[key] = value
          end
        end

        env.response.headers["Access-Control-Allow-Origin"] = "*"

        if response.status_code >= 300 && response.status_code != 404
          env.response.headers.delete("Transfer-Encoding")
          break
        end

        Helpers.proxy_file(response, env)
      end
    rescue ex
    end
  end

  def self.thumbnails(env)
    id = env.params.url["id"]
    name = env.params.url["name"]

    headers = HTTP::Headers.new

    if name == "maxres.jpg"
      build_thumbnails(id).each do |thumb|
        thumbnail_resource_path = "/vi/#{id}/#{thumb[:url]}.jpg"
        if get_ytimg_pool("i").client &.head(thumbnail_resource_path, headers).status_code == 200
          name = thumb[:url] + ".jpg"
          break
        end
      end
    end

    url = "/vi/#{id}/#{name}"

    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      get_ytimg_pool("i").client &.get(url, headers) do |resp|
        return self.proxy_image(env, resp)
      end
    rescue ex
    end
  end

  # DeArrow thumbnails: a frame of the video itself, picked by the crowd and
  # rendered by the DeArrow thumbnail cache. Proxied like every other image,
  # so that server never sees the viewer either.
  #
  # A frame that hasn't been rendered yet is answered with a 204 rather than
  # an image. Instead of leaving a hole in the page we serve YouTube's
  # thumbnail, and tell the browser to come back soon: by then the DeArrow
  # one is usually ready.
  def self.dearrow_thumbnail(env)
    id = env.params.url["id"]
    if !validate_video_id(id)
      haltf env, 400, ""
    end

    time = env.params.query["time"]?.try &.to_f?

    if CONFIG.dearrow.enabled && CONFIG.dearrow.thumbnails && time && time >= 0
      server = CONFIG.dearrow.thumbnail_server

      params = URI::Params.build do |form|
        form.add("videoID", id)
        form.add("time", time.to_s)
      end

      begin
        make_client(server) do |client|
          client.get("#{server.request_target.rchop('/')}/api/v1/getThumbnail?#{params}") do |resp|
            if resp.status_code == 200
              cache_control = "public, max-age=#{CONFIG.dearrow.cache_ttl}"
              return self.proxy_image(env, resp, cache_control: cache_control)
            end
          end
        end
      rescue ex
        LOGGER.debug("DeArrow: thumbnail of #{id} at #{time}s failed: #{ex.message}")
      end
    end

    self.dearrow_thumbnail_fallback(env, id)
  end

  private def self.dearrow_thumbnail_fallback(env, id : String)
    headers = HTTP::Headers.new

    REQUEST_HEADERS_WHITELIST.each do |header|
      if env.request.headers[header]?
        headers[header] = env.request.headers[header]
      end
    end

    begin
      get_ytimg_pool("i").client &.get("/vi/#{id}/mqdefault.jpg", headers) do |resp|
        # Deliberately short: this is the picture we didn't want to show.
        return self.proxy_image(env, resp, cache_control: "public, max-age=60")
      end
    rescue ex
    end
  end

  # `cache_control`, when given, replaces whatever the upstream server had to
  # say about caching.
  private def self.proxy_image(env, response, cache_control : String? = nil)
    env.response.status_code = response.status_code
    response.headers.each do |key, value|
      if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
        env.response.headers[key] = value
      end
    end

    env.response.headers["Cache-Control"] = cache_control if cache_control
    env.response.headers["Access-Control-Allow-Origin"] = "*"

    if response.status_code >= 300
      return env.response.headers.delete("Transfer-Encoding")
    end

    return Helpers.proxy_file(response, env)
  end
end
