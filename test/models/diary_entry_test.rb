require "test_helper"

class DiaryEntryTest < ActiveSupport::TestCase
  def create_segment(session_id, external_id, start, hours: 1)
    first = Message.create!(source: "claude_ai", external_id:, session_id:, role: "human", body: "原本", occurred_at: start)
    last = Message.create!(source: "claude_ai", external_id: "#{external_id}-b", session_id:, role: "assistant", body: "返答", occurred_at: start + hours.hours)
    segment = Segment.create!(session_id:, segment_date: start.to_date, first_message: first, last_message: last, started_at: first.occurred_at,
                              ended_at: last.occurred_at, start_reason: "first", end_reason: "gap")
    [ segment, first ]
  end

  def entry_attributes(segment, **overrides)
    { segment:, entry_date: segment.segment_date, note: {}, validation: {}, model: "dummy-model",
      prompt_version: "A-test", rule_version: "rules-test", input_digest: "abc123" }.merge(overrides)
  end

  setup do
    @segment, @message = create_segment("s-1", "m-1", Time.zone.parse("2026-10-26 10:00"))
    @entry = DiaryEntry.create!(entry_attributes(@segment, body_kanbun: "記事。"))
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

  test "ダイアリーは座ごとに1件。同じ座に2件目は作れない（モデルとDBの両方）" do
    assert_not DiaryEntry.new(entry_attributes(@segment)).valid?
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) { DiaryEntry.new(entry_attributes(@segment)).save!(validate: false) }
    end
  end

  test "同じ日付の別の座のダイアリーは作れる（entry_date は一意ではない）" do
    other, = create_segment("s-2", "m-2", Time.zone.parse("2026-10-26 15:00"))
    second = DiaryEntry.create!(entry_attributes(other))
    assert_equal @entry.entry_date, second.entry_date
    assert_equal 2, DiaryEntry.where(entry_date: @entry.entry_date).count
  end

  test "作り直しは同じ行を更新する。注釈は残り、リンクは入れ替わる" do
    annotation = @entry.annotations.create!(body: "後日考")
    other_message = Message.create!(source: "claude_ai", external_id: "m-9", session_id: "s-1", role: "human", body: "別の発言", occurred_at: Time.zone.parse("2026-10-26 10:30"))
    id = @entry.id
    DiaryEntry.transaction do
      @entry.update!(note: { "決定" => [] }, rule_version: "rules-test-2", input_digest: "def456")
      @entry.diary_links.delete_all
      @entry.diary_links.create!(message: other_message, item_key: "決定:0", link_kind: "source")
    end
    reloaded = DiaryEntry.find_by!(segment_id: @segment.id)
    assert_equal id, reloaded.id
    assert_equal "rules-test-2", reloaded.rule_version
    assert_equal [ annotation.id ], reloaded.annotations.pluck(:id)
    assert_equal [ other_message.id ], reloaded.diary_links.pluck(:message_id)
  end

  test "ダイアリーのある座は、消せない（モデルとDBの外部キー）" do
    assert_raises(ActiveRecord::DeleteRestrictionError) { @segment.destroy }
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.transaction(requires_new: true) { Segment.where(id: @segment.id).delete_all }
    end
  end

  test "座に結ぶので、segment がないダイアリーは作れない" do
    assert_not DiaryEntry.new(entry_attributes(@segment).merge(segment: nil)).valid?
  end

  test "規則・プロンプトの版と入力のダイジェストは必須（DB）" do
    other, = create_segment("s-3", "m-3", Time.zone.parse("2026-10-27 10:00"))
    %i[ model prompt_version rule_version input_digest ].each do |column|
      assert_raises(ActiveRecord::NotNullViolation, "#{column} は NOT NULL") do
        ActiveRecord::Base.transaction(requires_new: true) { DiaryEntry.new(entry_attributes(other, column => nil)).save!(validate: false) }
      end
    end
  end

  test "body_kanbun と body_kundoku は残してあり、空でよい" do
    assert_nil DiaryEntry.find(@entry.id).body_kundoku
    assert_equal "記事。", DiaryEntry.find(@entry.id).body_kanbun
  end
end
