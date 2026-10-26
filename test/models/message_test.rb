require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    @message = Message.create!(
      source: "claude_ai", external_id: "m-1", session_id: "s-1",
      role: "human", body: "原本", occurred_at: Time.zone.parse("2026-10-26 10:00")
    )
  end

  test "persisted message is readonly" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @message.update!(body: "改竄") }
  end

  test "persisted message cannot be destroyed" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @message.destroy }
  end

  test "database rejects update and delete that bypass the model" do
    assert_rejected_by_trigger("UPDATE") { Message.where(id: @message.id).update_all(body: "改竄") }
    assert_rejected_by_trigger("DELETE") { Message.where(id: @message.id).delete_all }
    assert_equal "原本", Message.find(@message.id).body
  end

  test "same external_id from the same source is rejected" do
    duplicate = @message.dup
    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "on_date selects messages of that day" do
    assert_equal [ @message ], Message.on_date(Date.new(2026, 10, 26)).to_a
    assert_empty Message.on_date(Date.new(2026, 10, 27))
  end

  private
    # Each statement runs in its own savepoint so a rejected one does not abort the test transaction.
    def assert_rejected_by_trigger(operation, &block)
      error = assert_raises(ActiveRecord::StatementInvalid) { Message.transaction(requires_new: true, &block) }
      assert_match "messages is append-only (#{operation} rejected)", error.message
    end
end
