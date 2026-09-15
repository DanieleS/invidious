require "../../parsers_helper.cr"

Spectator.describe Invidious::Videos::SponsorBlock do
  # An answer as the SponsorBlock API sends it: every video whose ID shares the
  # requested hash prefix, ours somewhere in the middle.
  let(body) do
    <<-JSON
      [
        {
          "videoID": "aaaaaaaaaaa",
          "hash": "d1f4cafedeadbeef",
          "segments": [
            {
              "UUID": "other-video",
              "category": "sponsor",
              "actionType": "skip",
              "segment": [10.0, 20.0],
              "videoDuration": 100.0,
              "locked": 0,
              "votes": 3
            }
          ]
        },
        {
          "videoID": "dQw4w9WgXcQ",
          "hash": "d1f40123456789ab",
          "segments": [
            {
              "UUID": "second",
              "category": "selfpromo",
              "actionType": "skip",
              "segment": [120.5, 140.25],
              "videoDuration": 212.0,
              "locked": 1,
              "votes": 8
            },
            {
              "UUID": "first",
              "category": "sponsor",
              "actionType": "mute",
              "segment": [3.0, 17.5],
              "videoDuration": 212.0,
              "locked": 0,
              "votes": 2
            }
          ]
        }
      ]
      JSON
  end

  describe "#parse" do
    it "keeps only the segments of the requested video" do
      segments = described_class.parse(body, "dQw4w9WgXcQ")

      expect(segments.map(&.uuid)).to eq(["first", "second"])
    end

    it "returns nothing when the video isn't in the answer" do
      expect(described_class.parse(body, "AAAAAAAAAAA")).to be_empty
    end

    it "reads times, categories and actions" do
      segment = described_class.parse(body, "dQw4w9WgXcQ")[1]

      expect(segment.category).to eq("selfpromo")
      expect(segment.action_type).to eq("skip")
      expect(segment.start_time).to eq(120.5)
      expect(segment.end_time).to eq(140.25)
      expect(segment.locked).to eq(1)
      expect(segment.votes).to eq(8)
    end

    it "drops segments the player couldn't use" do
      junk = <<-JSON
        [
          {
            "videoID": "dQw4w9WgXcQ",
            "segments": [
              {"UUID": "backwards", "category": "sponsor", "actionType": "skip", "segment": [50.0, 20.0]},
              {"UUID": "empty", "category": "sponsor", "actionType": "skip", "segment": [30.0, 30.0]},
              {"UUID": "negative", "category": "sponsor", "actionType": "skip", "segment": [-5.0, 10.0]},
              {"UUID": "truncated", "category": "sponsor", "actionType": "skip", "segment": [10.0]},
              {"UUID": "whole-video", "category": "sponsor", "actionType": "full", "segment": [0.0, 0.0]},
              {"UUID": "unknown-category", "category": "not_a_category", "actionType": "skip", "segment": [1.0, 2.0]},
              {"UUID": "good", "category": "intro", "actionType": "skip", "segment": [0.0, 12.0]}
            ]
          }
        ]
        JSON

      expect(described_class.parse(junk, "dQw4w9WgXcQ").map(&.uuid)).to eq(["good"])
    end
  end
end
