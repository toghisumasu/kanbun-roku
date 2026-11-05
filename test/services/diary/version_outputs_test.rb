require "test_helper"
require_relative "../../support/diary_helpers"

class Diary::VersionOutputsTest < ActiveSupport::TestCase
  include DiaryHelpers

  def segment
    @segment ||= create_segment([ [ "user", "データベースの設計を見直したい。", 0 ], [ "assistant", "返答", 1 ], [ "user", "次の作業は来週にします。", 2 ] ])
  end

  def record(version, output)
    built = Diary::InputBuilder.call(segment, detector: empty_detector)
    chunk = built.chunks.first
    DiaryChunk.create!(segment:, chunk_index: 0, input_digest: chunk.digest, model: "dummy-model", prompt_version: version,
                       status: "succeeded", raw_output: output)
  end

  def outputs(version) = Diary::VersionOutputs.call(segment, detector: empty_detector, model: "dummy-model", prompt_version: version)

  test "版ごとの塊の記録から組み立てる。別の版の記録は混ざらない。DB には書かない" do
    record("A-old", a_json("決定" => [ [ "来週にすると決めた", "次の作業は来週にします" ] ]))
    record("A-new", a_json("人間の依頼・共有" => [ [ "見直しを依頼した", "データベースの設計を見直したい" ] ]))
    old = outputs("A-old")
    new = outputs("A-new")
    assert_equal [ 1, 0 ], [ old.post.items["決定"].size, old.post.items["人間の依頼・共有"].size ]
    assert_equal [ 0, 1 ], [ new.post.items["決定"].size, new.post.items["人間の依頼・共有"].size ]
    assert_equal "A-old", old.outputs.validation["prompt_version"]
    assert_equal "A-new", new.outputs.validation["prompt_version"]
    assert_equal 0, DiaryEntry.count
  end

  test "後処理(c)の前後で決定の数が変わる（語尾が「ください」で決定語がない項目は依頼へ移る）" do
    record("A-x", a_json("決定" => [ [ "資料を求めた", "資料を送ってください" ] ]))
    r = outputs("A-x")
    assert_equal 1, r.notes.sum { |n| n["決定"].size }
    assert_equal 0, r.post.items["決定"].size
    assert_equal 1, r.post.moved.size
  end

  test "塊の記録がなければ nil" do
    assert_nil outputs("A-none")
  end

  test "Reassembler に旧版を指定すると、旧版の塊から組み立て、prompt_version もその版で書く" do
    record("A-old", a_json("決定" => [ [ "来週にすると決めた", "次の作業は来週にします" ] ]))
    Diary::Assembler.call(segment:, model: "dummy-model", input_digest: "x", items: Diary::Rules::HEADINGS.to_h { |h| [ h, [] ] },
                          validation: {}, links: [], prompt_version: "A-new")
    assert_equal :skipped_no_chunk, Diary::Reassembler.call(segment, detector: empty_detector, apply: true).status
    r = Diary::Reassembler.call(segment, detector: empty_detector, apply: true, prompt_version: "A-old")
    assert_equal :reassembled, r.status
    entry = DiaryEntry.find_by!(segment_id: segment.id)
    assert_equal "A-old", entry.prompt_version
    assert_equal "A-old", entry.validation["prompt_version"]
    assert_equal 1, entry.note["決定"].size
  end
end
