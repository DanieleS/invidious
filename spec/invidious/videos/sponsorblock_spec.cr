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

    it "keeps the highlight, a single point in time" do
      poi = <<-JSON
        [
          {
            "videoID": "dQw4w9WgXcQ",
            "segments": [
              {"UUID": "poi", "category": "poi_highlight", "actionType": "poi", "segment": [212.0, 212.0], "votes": 5}
            ]
          }
        ]
        JSON

      segments = described_class.parse(poi, "dQw4w9WgXcQ")

      expect(segments.map(&.uuid)).to eq(["poi"])
      expect(segments[0].highlight?).to be_true
      expect(segments[0].start_time).to eq(212.0)
    end

    it "keeps chapters, with their name" do
      chapters = <<-JSON
        [
          {
            "videoID": "dQw4w9WgXcQ",
            "segments": [
              {"UUID": "c2", "category": "chapter", "actionType": "chapter", "segment": [60.0, 120.0], "description": "Il ritornello"},
              {"UUID": "c1", "category": "chapter", "actionType": "chapter", "segment": [0.0, 60.0], "description": "La strofa"},
              {"UUID": "unnamed", "category": "chapter", "actionType": "chapter", "segment": [120.0, 180.0], "description": ""}
            ]
          }
        ]
        JSON

      segments = described_class.parse(chapters, "dQw4w9WgXcQ")

      expect(segments.map(&.description)).to eq(["La strofa", "Il ritornello"])
      expect(segments.all?(&.chapter?)).to be_true
    end

    it "survives a server that answers with booleans where the reference one has numbers" do
      odd = <<-JSON
        [
          {
            "videoID": "dQw4w9WgXcQ",
            "segments": [
              {"UUID": "a", "category": "sponsor", "actionType": "skip", "segment": [1.0, 2.0], "locked": true, "votes": 3}
            ]
          }
        ]
        JSON

      segments = described_class.parse(odd, "dQw4w9WgXcQ")

      expect(segments.map(&.uuid)).to eq(["a"])
      expect(segments[0].locked).to eq(1)
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
              {"UUID": "poi-wrong-category", "category": "sponsor", "actionType": "poi", "segment": [5.0, 5.0]},
              {"UUID": "chapter-without-name", "category": "chapter", "actionType": "chapter", "segment": [1.0, 9.0]},
              {"UUID": "good", "category": "intro", "actionType": "skip", "segment": [0.0, 12.0]}
            ]
          }
        ]
        JSON

      expect(described_class.parse(junk, "dQw4w9WgXcQ").map(&.uuid)).to eq(["good"])
    end
  end

  describe "#parse_label" do
    let(labels) do
      <<-JSON
        [
          {"videoID": "aaaaaaaaaaa", "segments": [{"category": "selfpromo"}]},
          {"videoID": "dQw4w9WgXcQ", "segments": [{"category": "exclusive_access"}]}
        ]
        JSON
    end

    it "reads the label of the requested video" do
      expect(described_class.parse_label(labels, "dQw4w9WgXcQ")).to eq("exclusive_access")
    end

    it "returns nothing for a video without one" do
      expect(described_class.parse_label(labels, "AAAAAAAAAAA")).to be_nil
    end

    it "ignores a category a whole video can't be labelled with" do
      odd = %([{"videoID": "dQw4w9WgXcQ", "segments": [{"category": "intro"}]}])

      expect(described_class.parse_label(odd, "dQw4w9WgXcQ")).to be_nil
    end
  end
end
