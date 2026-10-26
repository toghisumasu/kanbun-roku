require "test_helper"

class DiaryEntryTest < ActiveSupport::TestCase
  setup do
    @message = Message.create!(
      source: "claude_ai", external_id: "m-1", session_id: "s-1",
      role: "human", body: "原本", occurred_at: Time.zone.parse("2026-10-26 10:00")
    )
    @entry = DiaryEntry.create!(entry_date: Date.new(2026, 10, 26), body_kanbun: "記事。")
    @entry.diary_links.create!(message: @message)
  end

  test "destroying a diary entry leaves the source message intact" do
    @entry.annotations.delete_all
    @entry.destroy!
    assert Message.exists?(@message.id)
    assert_equal 0, DiaryLink.count
  end

  test "diary entry with annotations cannot be destroyed" do
    @entry.annotations.create!(body: "後日考")
    assert_raises(ActiveRecord::DeleteRestrictionError) { @entry.destroy }
  end

  test "annotation can target a message without touching it" do
    @message.annotations.create!(body: "考察")
    assert_equal "原本", @message.reload.body
  end
end
