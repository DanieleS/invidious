require "../../parsers_helper.cr"

Spectator.describe Invidious::Videos::DeArrow do
  # An answer as the DeArrow API sends it: every video whose ID shares the
  # requested hash prefix, ours somewhere in the middle.
  let(body) do
    <<-JSON
      {
        "aaaaaaaaaaa": {
          "titles": [
            { "title": "Someone else's video", "original": false, "votes": 4, "locked": false, "UUID": "other-video" }
          ],
          "thumbnails": [],
          "randomTime": 0.1,
          "videoDuration": 60.0
        },
        "dQw4w9WgXcQ": {
          "titles": [
            { "title": "A perfectly honest title", "original": false, "votes": 9, "locked": false, "UUID": "voted" },
            { "title": "The one a moderator locked", "original": false, "votes": 1, "locked": true, "UUID": "locked" },
            { "title": "", "original": false, "votes": 0, "locked": false, "UUID": "empty" }
          ],
          "thumbnails": [
            { "timestamp": 42.5, "original": false, "votes": 3, "locked": false, "UUID": "frame" },
            { "timestamp": null, "original": false, "votes": 0, "locked": false, "UUID": "no-timestamp" }
          ],
          "randomTime": 0.25,
          "videoDuration": 212.0
        }
      }
      JSON
  end

  describe "#parse" do
    it "keeps every video of the answer, ours included" do
      answer = described_class.parse(body)

      expect(answer.keys.sort).to eq(["aaaaaaaaaaa", "dQw4w9WgXcQ"])
    end

    it "drops submissions nothing can be done with" do
      branding = described_class.parse(body)["dQw4w9WgXcQ"]

      expect(branding.titles.map(&.uuid)).to eq(["voted", "locked"])
      expect(branding.thumbnails.map(&.uuid)).to eq(["frame"])
    end

    it "reads the random frame the server offers" do
      branding = described_class.parse(body)["dQw4w9WgXcQ"]

      expect(branding.random_time).to eq(0.25)
      expect(branding.video_duration).to eq(212.0)
    end
  end

  describe "#title" do
    it "prefers a locked submission over a better voted one" do
      branding = described_class.parse(body)["dQw4w9WgXcQ"]

      expect(branding.title).to eq("The one a moderator locked")
    end

    it "keeps YouTube's title when the crowd voted for it" do
      branding = Invidious::Videos::DeArrow::Branding.build(
        titles: [Invidious::Videos::DeArrow::Title.build("What the uploader wrote", original: true, votes: 5)]
      )

      expect(branding.title).to be_nil
    end

    it "keeps YouTube's title when every submission was voted down" do
      branding = Invidious::Videos::DeArrow::Branding.build(
        titles: [Invidious::Videos::DeArrow::Title.build("Clickbait, but worse", votes: -2)]
      )

      expect(branding.title).to be_nil
    end

    it "keeps YouTube's title when nothing was submitted" do
      expect(Invidious::Videos::DeArrow::Branding.build.title).to be_nil
    end
  end

  describe "#clean_title" do
    it "removes the markers that protect deliberate capitals" do
      expect(described_class.clean_title(">NASA lands on the moon")).to eq("NASA lands on the moon")
      expect(described_class.clean_title("A day at >NASA")).to eq("A day at NASA")
    end

    it "leaves a lone angle bracket alone" do
      expect(described_class.clean_title("5 > 3, obviously")).to eq("5 > 3, obviously")
    end
  end

  describe "#thumbnail_time" do
    it "uses the frame the crowd submitted" do
      branding = described_class.parse(body)["dQw4w9WgXcQ"]

      expect(branding.thumbnail_time(random: false)).to eq(42.5)
    end

    it "keeps YouTube's thumbnail when the crowd voted for it" do
      branding = Invidious::Videos::DeArrow::Branding.build(
        thumbnails: [Invidious::Videos::DeArrow::Thumbnail.build(original: true, votes: 5)],
        random_time: 0.5,
        video_duration: 100.0
      )

      expect(branding.thumbnail_time(random: true)).to be_nil
    end

    it "falls back to a random frame only when asked to" do
      branding = Invidious::Videos::DeArrow::Branding.build(random_time: 0.5, video_duration: 100.0)

      expect(branding.thumbnail_time(random: false)).to be_nil
      expect(branding.thumbnail_time(random: true)).to eq(50.0)
    end

    it "has nothing to fall back to without a duration" do
      branding = Invidious::Videos::DeArrow::Branding.build(random_time: 0.5)

      expect(branding.thumbnail_time(random: true)).to be_nil
    end
  end
end
