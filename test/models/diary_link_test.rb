require "test_helper"

class DiaryLinkTest < ActiveSupport::TestCase
  setup do
    first = Message.create!(source: "claude_ai", external_id: "l-1", session_id: "s-l", role: "human", body: "依頼", occurred_at: Time.zone.parse("2026-10-26 10:00"))
    @last = Message.create!(source: "claude_ai", external_id: "l-2", session_id: "s-l", role: "assistant", body: "提案", occurred_at: Time.zone.parse("2026-10-26 10:01"))
    segment = Segment.create!(session_id: "s-l", segment_date: Date.new(2026, 10, 26), first_message: first, last_message: @last,
                              started_at: first.occurred_at, ended_at: @last.occurred_at, start_reason: "first", end_reason: "gap")
    @first = first
    @entry = DiaryEntry.create!(segment:, entry_date: segment.segment_date, model: "m", prompt_version: "p", rule_version: "r", input_digest: "d")
  end

  test "link_kind の既定は source。決められた種類だけ許す" do
    link = @entry.diary_links.create!(message: @first)
    assert_equal "source", link.link_kind
    assert DiaryLink.new(diary_entry: @entry, message: @first, link_kind: "preceding_assistant_candidate", item_key: "決定:0").valid?
    assert_not DiaryLink.new(diary_entry: @entry, message: @first, link_kind: "guess").valid?
  end

  test "同じ発言に、別の項目・別の種類のリンクを付けられる" do
    @entry.diary_links.create!(message: @first, item_key: "決定:0", link_kind: "source")
    @entry.diary_links.create!(message: @first, item_key: "人間の考え:0", link_kind: "source")
    @entry.diary_links.create!(message: @first, item_key: "決定:0", link_kind: "preceding_assistant_candidate")
    assert_equal 3, @entry.diary_links.count
  end

  test "同じ項目・同じ発言・同じ種類のリンクは重複できない（モデル）" do
    @entry.diary_links.create!(message: @first, item_key: "決定:0")
    assert_not DiaryLink.new(diary_entry: @entry, message: @first, item_key: "決定:0").valid?
  end

  test "item_key が NULL のリンクも、1組につき1本（DBの nulls_not_distinct）" do
    @entry.diary_links.create!(message: @first)
    assert_not DiaryLink.new(diary_entry: @entry, message: @first).valid?
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) { DiaryLink.new(diary_entry: @entry, message: @first).save!(validate: false) }
    end
  end

  test "ダイアリーを消すとリンクも消えるが、原本の発言は残る" do
    @entry.diary_links.create!(message: @first, item_key: "決定:0")
    @entry.destroy!
    assert_equal 0, DiaryLink.count
    assert Message.exists?(@first.id)
  end
end
