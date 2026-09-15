#
# Read-only DeArrow client.
#
# DeArrow (https://dearrow.ajay.app) is SponsorBlock's sibling project: a
# crowd-sourced database of *titles* and *thumbnails*, submitted and voted on
# by viewers to replace the ones the uploader picked. Like the SponsorBlock
# module next door, this one only *reads* that database; submitting or voting
# needs a private user ID, which a shared instance is the wrong place to keep.
#
# The same two properties hold as for SponsorBlock:
#
#   * The request is made by the instance, not by the browser, so the DeArrow
#     server never sees the viewer's IP address.
#
#   * The video ID is never sent. The public API accepts the first four hex
#     characters of its SHA-256 instead, and answers with every video sharing
#     that prefix. We pick ours out of the pile locally.
#
# What sets DeArrow apart from SponsorBlock is *when* the answer is needed: a
# page of search results wants twenty titles before it can be drawn, not one.
# Hence `prefetch`, which warms the cache for a whole page in parallel and
# gives up after a short while: a slow DeArrow server costs the page nothing
# but its original titles, and what arrives late is still cached for the next
# load.
#
module Invidious::Videos::DeArrow
  extend self

  # A submission is shown when it is locked (a moderator decision) or when the
  # crowd hasn't voted it down. This is the same threshold the browser
  # extension uses, and it's deliberately not configurable: an instance
  # silently showing titles the community rejected would be worse than not
  # showing any.
  MIN_VOTES = 0

  struct Title
    include JSON::Serializable

    property title : String

    # True when this submission *is* the title YouTube already shows, which
    # the crowd may well consider the best one.
    property original : Bool = false

    property votes : Int32 = 0
    property locked : Bool = false

    @[JSON::Field(key: "UUID")]
    property uuid : String = ""

    def initialize(@title, @original = false, @votes = 0, @locked = false, @uuid = "")
    end
  end

  struct Thumbnail
    include JSON::Serializable

    # Second of the video the frame is taken from. Absent on submissions that
    # only say "the original one is fine".
    property timestamp : Float64? = nil

    property original : Bool = false
    property votes : Int32 = 0
    property locked : Bool = false

    @[JSON::Field(key: "UUID")]
    property uuid : String = ""

    def initialize(@timestamp = nil, @original = false, @votes = 0, @locked = false, @uuid = "")
    end
  end

  # Everything the crowd has to say about one video. An empty one (nothing
  # submitted, or nothing that survived the vote) is a perfectly normal
  # answer, and means "leave the video as YouTube shows it".
  struct Branding
    include JSON::Serializable

    property titles : Array(Title) = [] of Title
    property thumbnails : Array(Thumbnail) = [] of Thumbnail

    # A frame picked at random by the DeArrow server, used when nobody has
    # submitted a thumbnail. It is a *fraction* of the video, not a second.
    @[JSON::Field(key: "randomTime")]
    property random_time : Float64? = nil

    @[JSON::Field(key: "videoDuration")]
    property video_duration : Float64? = nil

    def initialize(
      @titles = [] of Title,
      @thumbnails = [] of Thumbnail,
      @random_time = nil,
      @video_duration = nil,
    )
    end

    # The title to show, or nil to keep YouTube's.
    def title : String?
      chosen = DeArrow.pick(titles)
      return nil if chosen.nil? || chosen.original

      cleaned = DeArrow.clean_title(chosen.title)
      cleaned.empty? ? nil : cleaned
    end

    # Second of the video the thumbnail should be taken from, or nil to keep
    # YouTube's.
    #
    # `random` enables DeArrow's own fallback: when nobody submitted a
    # thumbnail, show a frame the server picked at random rather than the one
    # the uploader chose. It is off by default on an instance, because unlike
    # in the extension every such frame is rendered and proxied by us.
    def thumbnail_time(random : Bool) : Float64?
      chosen = DeArrow.pick(thumbnails)

      if chosen
        # A submission marked "original" is the crowd saying the uploader's
        # thumbnail is the right one; a random frame would overrule them.
        return nil if chosen.original

        timestamp = chosen.timestamp
        return timestamp if timestamp && timestamp >= 0
      end

      return nil if !random

      fraction = random_time
      duration = video_duration
      return nil if fraction.nil? || duration.nil?
      return nil if fraction < 0 || fraction > 1 || duration <= 0

      fraction * duration
    end
  end

  # Picks the submission to use out of a list the server sends already sorted
  # by score: a locked one wins outright, otherwise the best one the crowd
  # hasn't voted down.
  def pick(entries : Array(T)) : T? forall T
    entries.find(&.locked) || entries.find { |entry| entry.votes >= MIN_VOTES }
  end

  # Submitters mark a word with a leading ">" to say "these capitals are
  # deliberate, don't touch them". That marker is for the clients that reformat
  # titles; we don't, so it only has to go.
  def clean_title(title : String) : String
    title.gsub(/(\A|\s)>(\S)/) { "#{$1}#{$2}" }.strip
  end

  # Cached answers, keyed by video ID. Videos nobody has touched are cached as
  # an empty `Branding` too: without that, the majority of videos would be
  # looked up again on every single page load.
  private CACHE = {} of String => {Time, Branding}

  # Beyond this, the oldest half of the cache is thrown away. Entries are
  # small, so this is a few MB at worst.
  private CACHE_LIMIT = 4096

  # Branding for a single video, fetched right away if it isn't cached.
  #
  # Raises if the DeArrow server can't be reached or answers with something
  # unexpected. Page rendering doesn't use this: it goes through `prefetch`,
  # which never raises and never waits for long.
  def branding(video_id : String) : Branding
    return Branding.new if !validate_video_id(video_id)

    cached(video_id) || begin
      fetch_and_cache(prefix_of(video_id), [video_id])
      cached(video_id) || Branding.new
    end
  end

  # Branding for a video *if it has already been fetched*. Never touches the
  # network, so a template can call it once per card without turning a page
  # into a few dozen HTTP requests in a row.
  def cached_branding(video_id : String) : Branding?
    cached(video_id)
  end

  # Warms the cache for everything a page is about to draw.
  #
  # Videos are grouped by hash prefix, so the handful that happen to share one
  # cost a single request, and the requests are made in parallel. Whatever
  # isn't in by the deadline is simply not used: the fibers keep going and
  # fill the cache for the next load.
  def prefetch(video_ids : Array(String)) : Nil
    return if !CONFIG.dearrow.enabled

    missing = video_ids.uniq.select { |id| validate_video_id(id) && cached(id).nil? }
    return if missing.empty?

    batches = missing.group_by { |id| prefix_of(id) }

    # Buffered, so that a fiber finishing after the deadline doesn't block on
    # a channel nobody reads any more.
    done = Channel(Nil).new(batches.size)

    batches.each do |prefix, ids|
      spawn do
        begin
          fetch_and_cache(prefix, ids)
        rescue ex
          LOGGER.debug("DeArrow: lookup of #{prefix} failed: #{ex.message}")
        ensure
          done.send(nil)
        end
      end
    end

    deadline = Time.monotonic + CONFIG.dearrow.timeout.milliseconds
    remaining = batches.size

    while remaining > 0
      left = deadline - Time.monotonic
      break if left <= Time::Span.zero

      select
      when done.receive
        remaining -= 1
      when timeout(left)
        LOGGER.debug("DeArrow: #{remaining} lookup(s) still pending after #{CONFIG.dearrow.timeout}ms")
        break
      end
    end
  end

  private def prefix_of(video_id : String) : String
    sha256(video_id)[0, 4]
  end

  private def cached(video_id : String) : Branding?
    entry = CACHE[video_id]?
    return nil if entry.nil?

    expires, branding = entry
    if Time.utc > expires
      CACHE.delete(video_id)
      return nil
    end

    branding
  end

  private def fetch_and_cache(prefix : String, video_ids : Array(String)) : Nil
    answer = fetch(prefix)

    prune_cache if CACHE.size >= CACHE_LIMIT
    expires = Time.utc + CONFIG.dearrow.cache_ttl.seconds

    video_ids.each do |video_id|
      CACHE[video_id] = {expires, answer[video_id]? || Branding.new}
    end
  end

  # Drops expired entries, and if that wasn't enough, the oldest half.
  private def prune_cache : Nil
    now = Time.utc
    CACHE.reject! { |_, (expires, _)| now > expires }

    return if CACHE.size < CACHE_LIMIT

    CACHE.to_a
      .sort_by! { |(_, (expires, _))| expires }
      .first(CACHE.size // 2)
      .each { |(key, _)| CACHE.delete(key) }
  end

  private def fetch(prefix : String) : Hash(String, Branding)
    server = CONFIG.dearrow.server
    response = make_client(server, &.get("#{server.request_target.rchop('/')}/api/branding/#{prefix}"))

    # 404 is the documented answer for "nothing is known about any video with
    # that hash prefix", which is a legitimate empty result.
    return {} of String => Branding if response.status_code == 404
    raise "DeArrow server answered #{response.status_code}" if response.status_code != 200

    parse(response.body)
  end

  # The hash-prefix answer is a map of video ID to branding. Submissions that
  # can't be used for anything are dropped here, so that everything downstream
  # only ever sees a usable list.
  def parse(body : String) : Hash(String, Branding)
    answer = Hash(String, Branding).from_json(body)

    answer.each_value do |branding|
      branding.titles.select! { |title| !title.title.blank? }
      branding.thumbnails.select! do |thumbnail|
        next true if thumbnail.original

        timestamp = thumbnail.timestamp
        !timestamp.nil? && timestamp >= 0
      end
    end

    answer
  end
end
