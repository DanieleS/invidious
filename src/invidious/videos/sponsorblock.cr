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
# Besides the segments to skip, the same database holds three other things we
# read here: the "highlight" (the point where the video actually gets to the
# matter), chapter names written by hand, and full-video labels ("this whole
# thing is a sponsor").
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

  # Categories that describe a stretch of video to get past. These are the
  # ones a user can pick from, and the only ones the player ever skips.
  # Anything else coming from a request (or from a hand-edited preferences
  # cookie) is dropped, so that we never forward junk to the SponsorBlock
  # server.
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

  # The two categories that aren't about skipping: a single point to jump to,
  # and the hand-written chapters.
  HIGHLIGHT_CATEGORY = "poi_highlight"
  CHAPTER_CATEGORY   = "chapter"

  # Categories a whole video can be labelled with. Not a stretch of time, so
  # they come from a different endpoint and there is nothing to skip: we just
  # say so on the page.
  LABEL_CATEGORIES = ["sponsor", "selfpromo", "exclusive_access"]

  # What we ask the server for. Always everything, whatever this particular
  # viewer wants, so that one cached answer serves them all.
  REQUESTED_CATEGORIES = CATEGORIES + [HIGHLIGHT_CATEGORY, CHAPTER_CATEGORY]

  # "skip" jumps over the segment, "mute" only silences it; "poi" is the
  # single point of the highlight, "chapter" carries a name instead of
  # something to avoid. The remaining type, "full", labels an entire video and
  # has its own endpoint.
  SKIP_ACTIONS      = ["skip", "mute"]
  REQUESTED_ACTIONS = SKIP_ACTIONS + ["poi", "chapter"]

  # `locked` and `votes` are integers in the reference server's database, but
  # nothing in the API promises that, and a mirror could well answer with
  # booleans. Neither number changes what the player does, so a surprise here
  # must not cost us the whole lookup.
  module FlexibleInt
    def self.from_json(value : JSON::PullParser) : Int32
      case value.kind
      when .int?   then value.read_int.to_i32
      when .float? then value.read_float.to_i32
      when .bool?  then value.read_bool ? 1 : 0
      else
        value.skip
        0
      end
    end

    def self.to_json(value : Int32, json : JSON::Builder)
      json.number value
    end
  end

  struct Segment
    include JSON::Serializable

    @[JSON::Field(key: "UUID")]
    property uuid : String

    property category : String

    @[JSON::Field(key: "actionType")]
    property action_type : String

    # [start, end], in seconds. For a highlight the two are the same point.
    property segment : Array(Float64)

    # The chapter name. Empty for every other kind of segment.
    property description : String = ""

    @[JSON::Field(converter: Invidious::Videos::SponsorBlock::FlexibleInt)]
    property votes : Int32 = 0

    @[JSON::Field(converter: Invidious::Videos::SponsorBlock::FlexibleInt)]
    property locked : Int32 = 0

    @[JSON::Field(key: "videoDuration")]
    property video_duration : Float64 = 0.0

    def start_time : Float64
      @segment[0]? || 0.0
    end

    def end_time : Float64
      @segment[1]? || 0.0
    end

    def skip? : Bool
      SKIP_ACTIONS.includes?(@action_type)
    end

    def highlight? : Bool
      @action_type == "poi"
    end

    def chapter? : Bool
      @action_type == "chapter"
    end
  end

  # One entry of the hash-prefix answer: the segments known for a single video.
  private struct VideoEntry
    include JSON::Serializable

    @[JSON::Field(key: "videoID")]
    property video_id : String

    property segments : Array(Segment) = [] of Segment
  end

  # The full-video endpoint answers with the bare category, nothing else.
  struct VideoLabel
    include JSON::Serializable

    property category : String
  end

  private struct LabelEntry
    include JSON::Serializable

    @[JSON::Field(key: "videoID")]
    property video_id : String

    property segments : Array(VideoLabel) = [] of VideoLabel
  end

  # Cached answers, keyed by video ID. Labels live in their own cache because
  # they come from their own request, and most videos have none.
  private CACHE       = {} of String => {Time, Array(Segment)}
  private LABEL_CACHE = {} of String => {Time, String?}

  # Beyond this, the oldest half of a cache is thrown away. Segments are small
  # (a couple hundred bytes each), so this is a few MB at worst.
  private CACHE_LIMIT = 2048

  # Everything known about a video: skips, highlight and chapters together, as
  # they arrive in a single answer.
  #
  # Raises if the SponsorBlock server can't be reached or answers with
  # something unexpected; a video with nothing marked is an empty array, not
  # an error.
  def lookup(video_id : String) : Array(Segment)
    cached(CACHE, video_id) || store(CACHE, video_id, fetch(video_id))
  end

  # The segments to get past, restricted to the categories the viewer picked.
  def skips(segments : Array(Segment), categories : Array(String)) : Array(Segment)
    categories = categories.select { |category| CATEGORIES.includes?(category) }
    return [] of Segment if categories.empty?

    segments.select { |segment| segment.skip? && categories.includes?(segment.category) }
  end

  # The point where the video gets to the matter. At most one: if several were
  # submitted, the most supported one wins.
  def highlight(segments : Array(Segment)) : Segment?
    segments.select(&.highlight?).max_by?(&.votes)
  end

  # The hand-written chapters, in playing order. A chapter without a name is
  # nothing we can show, so it doesn't count.
  def chapters(segments : Array(Segment)) : Array(Segment)
    segments.select { |segment| segment.chapter? && !segment.description.blank? }
  end

  # The category a whole video is labelled with, if any. This is a second
  # request, so it's only made when someone asks for it.
  def label(video_id : String) : String?
    cached_label = LABEL_CACHE[video_id]?
    if cached_label
      expires, category = cached_label
      return category if Time.utc <= expires
      LABEL_CACHE.delete(video_id)
    end

    store(LABEL_CACHE, video_id, fetch_label(video_id))
  end

  private def cached(cache, key)
    entry = cache[key]?
    return nil if entry.nil?

    expires, value = entry
    if Time.utc > expires
      cache.delete(key)
      return nil
    end

    value
  end

  private def store(cache, key, value)
    prune(cache) if cache.size >= CACHE_LIMIT
    cache[key] = {Time.utc + CONFIG.sponsorblock.cache_ttl.seconds, value}

    value
  end

  # Drops expired entries, and if that wasn't enough, the oldest half.
  private def prune(cache) : Nil
    now = Time.utc
    cache.reject! { |_, (expires, _)| now > expires }

    return if cache.size < CACHE_LIMIT

    cache.to_a
      .sort_by! { |(_, (expires, _))| expires }
      .first(cache.size // 2)
      .each { |(key, _)| cache.delete(key) }
  end

  private def fetch(video_id : String) : Array(Segment)
    params = URI::Params.build do |form|
      form.add("categories", REQUESTED_CATEGORIES.to_json)
      form.add("actionTypes", REQUESTED_ACTIONS.to_json)
    end

    body = get("/api/skipSegments/#{hash_prefix(video_id)}?#{params}")
    return [] of Segment if body.nil?

    parse(body, video_id)
  end

  private def fetch_label(video_id : String) : String?
    body = get("/api/videoLabels/#{hash_prefix(video_id)}")
    return nil if body.nil?

    parse_label(body, video_id)
  end

  # The first four characters of the SHA-256: enough for the server to find
  # the video among the few hundred sharing the prefix, not enough to know
  # which one we're after.
  private def hash_prefix(video_id : String) : String
    sha256(video_id)[0, 4]
  end

  # Returns the response body, or nothing when the server has nothing for this
  # prefix. Anything else is an error worth surfacing.
  private def get(path : String) : String?
    server = CONFIG.sponsorblock.server
    response = make_client(server, &.get("#{server.request_target.rchop('/')}#{path}"))

    # 404 is the documented answer for "no video with that hash prefix has
    # anything to say", which is a legitimate empty result.
    return nil if response.status_code == 404
    raise "SponsorBlock server answered #{response.status_code}" if response.status_code != 200

    response.body
  end

  # Picks our video out of a hash-prefix answer and keeps only the segments
  # that make sense, in playing order. Everything downstream (the player
  # included) can then assume a sorted list where each segment says something
  # usable.
  def parse(body : String, video_id : String) : Array(Segment)
    entry = Array(VideoEntry).from_json(body).find { |item| item.video_id == video_id }
    return [] of Segment if entry.nil?

    entry.segments
      .select { |segment| usable?(segment) }
      .sort_by!(&.start_time)
  end

  # Same, for the full-video labels. Only the categories a video can actually
  # be labelled with are accepted.
  def parse_label(body : String, video_id : String) : String?
    entry = Array(LabelEntry).from_json(body).find { |item| item.video_id == video_id }
    return nil if entry.nil?

    entry.segments
      .map(&.category)
      .find { |category| LABEL_CATEGORIES.includes?(category) }
  end

  # Each kind of segment has its own idea of what "well formed" means: a
  # highlight is a single point, so start and end may coincide; a chapter
  # without a name has nothing to show; everything else has to be a stretch
  # with a beginning before its end.
  private def usable?(segment : Segment) : Bool
    return false if segment.segment.size != 2
    return false if segment.start_time < 0

    if segment.highlight?
      segment.category == HIGHLIGHT_CATEGORY && segment.end_time >= segment.start_time
    elsif segment.chapter?
      segment.category == CHAPTER_CATEGORY &&
        !segment.description.blank? &&
        segment.end_time > segment.start_time
    elsif segment.skip?
      CATEGORIES.includes?(segment.category) && segment.end_time > segment.start_time
    else
      false
    end
  end
end
