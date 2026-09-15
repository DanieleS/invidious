#
# Where DeArrow meets the pages.
#
# `Invidious::Videos::DeArrow` knows what the crowd submitted; this module
# decides whether the viewer asked to see it, and turns it into the title and
# the thumbnail URL a template can print.
#
# The rule everywhere is the same: a lookup that hasn't come back yet is not
# worth waiting for. Every page first calls `prefetch` once for everything it
# is about to draw, then asks for one title or thumbnail at a time out of the
# cache; anything missing simply stays as YouTube has it.
#
module Invidious::Frontend::DeArrow
  extend self

  def enabled?(prefs : Preferences) : Bool
    CONFIG.dearrow.enabled && prefs.dearrow
  end

  def titles?(prefs : Preferences) : Bool
    enabled?(prefs) && prefs.dearrow_titles
  end

  # Thumbnails are the expensive half, and the one an instance may have turned
  # off on its own; in thin mode there is no image to replace in the first
  # place.
  def thumbnails?(prefs : Preferences) : Bool
    return false if !enabled?(prefs) || prefs.thin_mode

    CONFIG.dearrow.thumbnails && prefs.dearrow_thumbnails
  end

  # Warms the cache for a list of video IDs, in one go.
  def prefetch_videos(env : HTTP::Server::Context, video_ids : Array(String)) : Nil
    prefs = env.get("preferences").as(Preferences)
    return if !titles?(prefs) && !thumbnails?(prefs)

    Invidious::Videos::DeArrow.prefetch(video_ids)
  end

  # Same, for a list of items as the templates hand them over (search results,
  # feeds, playlist entries...). Anything that isn't a video — a channel, a
  # playlist, a category header — is dropped on the way, by the simple fact
  # that its ID isn't shaped like a video ID.
  def prefetch(env : HTTP::Server::Context, items) : Nil
    video_ids = [] of String

    items.each do |item|
      next if !item.responds_to?(:id)

      id = item.id
      video_ids << id if id.is_a?(String)
    end

    prefetch_videos(env, video_ids)
  end

  # The title to print for a video: the crowd's one when there is one and the
  # viewer wants it, YouTube's otherwise.
  def title(env : HTTP::Server::Context, video_id : String, original : String) : String
    prefs = env.get("preferences").as(Preferences)
    return original if !titles?(prefs)

    Invidious::Videos::DeArrow.cached_branding(video_id).try(&.title) || original
  end

  # The thumbnail URL to print for a video.
  #
  # DeArrow's thumbnails are frames of the video itself, rendered on demand by
  # the thumbnail cache; they go through the instance like every other image,
  # and `/dearrow/thumbnail/:id` falls back to YouTube's on its own when the
  # frame isn't ready yet.
  def thumbnail(env : HTTP::Server::Context, video_id : String, fallback : String) : String
    prefs = env.get("preferences").as(Preferences)
    return fallback if !thumbnails?(prefs)

    branding = Invidious::Videos::DeArrow.cached_branding(video_id)
    return fallback if branding.nil?

    time = branding.thumbnail_time(CONFIG.dearrow.random_thumbnails)
    return fallback if time.nil?

    "/dearrow/thumbnail/#{video_id}?time=#{time.round(3)}"
  end
end
