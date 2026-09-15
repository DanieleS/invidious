#
# Read-only SponsorBlock client.
#
# SponsorBlock (https://github.com/ajayyy/SponsorBlock) is a crowd-sourced
# database of "segments to skip" inside YouTube videos: sponsor reads,
# self-promotion, intros, and so on. This module only *reads* that database;
# submitting or voting on segments is not supported, on purpose. Submissions
# are tied to a user ID that would have to be stored and kept secret, and a
# shared instance is the wrong place to keep one.
#
# Two things are worth noting about how the lookup is done:
#
#   * The request is made by the instance, not by the browser, so the
#     SponsorBlock server never sees the viewer's IP address.
#
#   * The video ID is never sent. The public API accepts the first four hex
#     characters of its SHA-256 instead, and answers with every video sharing
#     that prefix (a few hundred at most). We pick ours out of the pile
#     locally. This is the same trick the browser extension uses.
#
module Invidious::Videos::SponsorBlock
  extend self

  # Categories the upstream API knows about. Anything else coming from a
  # request (or from a hand-edited preferences cookie) is dropped, so that we
  # never forward junk to the SponsorBlock server.
  CATEGORIES = [
    "sponsor",
    "selfpromo",
    "interaction",
    "intro",
    "outro",
    "preview",
    "filler",
    "music_offtopic",
  ]

  # "skip" jumps over the segment, "mute" only silences it. The other action
  # types ("full", which labels a whole video, and "poi", a single point of
  # interest) don't describe a stretch of time to get past, so we don't ask
  # for them.
  ACTION_TYPES = ["skip", "mute"]

  struct Segment
    include JSON::Serializable

    @[JSON::Field(key: "UUID")]
    property uuid : String

    property category : String

    @[JSON::Field(key: "actionType")]
    property action_type : String

    # [start, end], in seconds.
    property segment : Array(Float64)

    property votes : Int32 = 0
    property locked : Int32 = 0

    @[JSON::Field(key: "videoDuration")]
    property video_duration : Float64 = 0.0

    def start_time : Float64
      @segment[0]? || 0.0
    end

    def end_time : Float64
      @segment[1]? || 0.0
    end
  end

  # One entry of the hash-prefix answer: the segments known for a single video.
  private struct VideoEntry
    include JSON::Serializable

    @[JSON::Field(key: "videoID")]
    property video_id : String

    property segments : Array(Segment) = [] of Segment
  end

  # Cached answers, keyed by video ID. We always fetch every category and
  # filter on the way out, so one entry serves every user whatever their
  # preferences are.
  private CACHE = {} of String => {Time, Array(Segment)}

  # Beyond this, the oldest half of the cache is thrown away. Segments are
  # small (a couple hundred bytes each), so this is a few MB at worst.
  private CACHE_LIMIT = 2048

  # Returns the segments known for `video_id`, restricted to `categories`.
  #
  # Raises if the SponsorBlock server can't be reached or answers with
  # something unexpected; a video with nothing to skip is an empty array, not
  # an error.
  def segments(video_id : String, categories : Array(String)) : Array(Segment)
    categories = categories.select { |category| CATEGORIES.includes?(category) }
    return [] of Segment if categories.empty?

    all = cached(video_id) || fetch_and_cache(video_id)

    all.select { |segment| categories.includes?(segment.category) }
  end

  private def cached(video_id : String) : Array(Segment)?
    entry = CACHE[video_id]?
    return nil if entry.nil?

    expires, segments = entry
    if Time.utc > expires
      CACHE.delete(video_id)
      return nil
    end

    segments
  end

  private def fetch_and_cache(video_id : String) : Array(Segment)
    segments = fetch(video_id)

    prune_cache if CACHE.size >= CACHE_LIMIT
    CACHE[video_id] = {Time.utc + CONFIG.sponsorblock.cache_ttl.seconds, segments}

    segments
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

  private def fetch(video_id : String) : Array(Segment)
    prefix = sha256(video_id)[0, 4]

    params = URI::Params.build do |form|
      form.add("categories", CATEGORIES.to_json)
      form.add("actionTypes", ACTION_TYPES.to_json)
    end

    server = CONFIG.sponsorblock.server
    response = make_client(server, &.get("#{server.request_target.rchop('/')}/api/skipSegments/#{prefix}?#{params}"))

    # 404 is the documented answer for "no video with that hash prefix has any
    # segment in the requested categories", which is a legitimate empty result.
    return [] of Segment if response.status_code == 404
    raise "SponsorBlock server answered #{response.status_code}" if response.status_code != 200

    parse(response.body, video_id)
  end

  # Picks our video out of a hash-prefix answer and keeps only the segments
  # that describe a usable stretch of time, in playing order. Everything
  # downstream (the player included) can then assume start < end and a sorted
  # list.
  def parse(body : String, video_id : String) : Array(Segment)
    entry = Array(VideoEntry).from_json(body).find { |item| item.video_id == video_id }
    return [] of Segment if entry.nil?

    entry.segments
      .select { |segment| ACTION_TYPES.includes?(segment.action_type) }
      .select { |segment| CATEGORIES.includes?(segment.category) }
      .select { |segment| segment.segment.size == 2 }
      .select { |segment| segment.start_time >= 0 && segment.end_time > segment.start_time }
      .sort_by!(&.start_time)
  end
end
