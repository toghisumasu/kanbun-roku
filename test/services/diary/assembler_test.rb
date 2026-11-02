require "test_helper"
require_relative "../../support/diary_helpers"

class Diary::AssemblerTest < ActiveSupport::TestCase
  include DiaryHelpers

  def setup_segment
    @segment = create_segment([ [ "assistant", "返答", 0 ], [ "user", "依頼", 1 ], [ "user", "決定します", 2 ] ])
    @messages = Message.where(session_id: @segment.session_id).order(:id).to_a
  end

  def items(*texts) = { "決定" => texts.map { |t| Diary::Item.new(heading: "決定", text: t, quote: "決定します", chunk_index: 0) } }

  def assemble(items, links, **options)
    Diary::Assembler.call(segment: @segment, model: "m", input_digest: "d1", items:, validation: { "counts" => {} }, links:, **options)
  end

  def link(key, message, kind = "source") = Diary::DecisionLinker::LinkSpec.new(item_key: key, message_id: message.id, link_kind: kind)

  test "座の DiaryEntry を作り、note・版・ダイジェスト・リンクを保存する" do
    setup_segment
    entry = assemble(items("決めた"), [ link("決定:0", @messages[2]), link("決定:0", @messages[0], "preceding_assistant_candidate") ])
    assert entry.persisted?
    assert_equal [ @segment.id, @segment.segment_date, "m", "d1" ], [ entry.segment_id, entry.entry_date, entry.model, entry.input_digest ]
    assert_equal [ Diary::Prompts::A::PROMPT_VERSION, Diary::Rules::VERSION ], [ entry.prompt_version, entry.rule_version ]
    assert_equal [ { "本文" => "決めた", "引用" => "決定します", "chunk" => 0 } ], entry.note["決定"]
    assert_equal 2, entry.diary_links.count
  end

  test "作り直しは同じ行を更新し、リンクを入れ替える。注釈は残る" do
    setup_segment
    first = assemble(items("決めた"), [ link("決定:0", @messages[2]) ])
    annotation = first.annotations.create!(body: "後日考")
    second = assemble(items("決め直した"), [ link("決定:0", @messages[1]) ])
    assert_equal first.id, second.id
    assert_equal 1, DiaryEntry.count
    assert_equal [ "決め直した" ], second.reload.note["決定"].map { |i| i["本文"] }
    assert_equal [ @messages[1].id ], second.diary_links.pluck(:message_id)
    assert_equal [ annotation.id ], second.annotations.pluck(:id)
  end

  test "途中で失敗したら、全体を巻き戻す（古いリンクを残す）" do
    setup_segment
    first = assemble(items("決めた"), [ link("決定:0", @messages[2]) ])
    bad = Diary::DecisionLinker::LinkSpec.new(item_key: "決定:0", message_id: 0, link_kind: "source") # 存在しない発言
    assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::InvalidForeignKey) { assemble(items("壊れる"), [ bad ]) }
    first.reload
    assert_equal [ "決めた" ], first.note["決定"].map { |i| i["本文"] }
    assert_equal [ @messages[2].id ], first.diary_links.pluck(:message_id)
  end

  test "note_for は、見出しごとに本文・引用・塊の位置を持つ" do
    note = Diary::Assembler.note_for("決定" => [ Diary::Item.new(heading: "決定", text: "t", quote: "q", chunk_index: 3) ], "未解決" => [])
    assert_equal({ "決定" => [ { "本文" => "t", "引用" => "q", "chunk" => 3 } ], "未解決" => [] }, note)
  end
end
