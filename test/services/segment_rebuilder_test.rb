require "test_helper"

# ダミーの会話だけを使う。
class SegmentRebuilderTest < ActiveSupport::TestCase
  def jst(*args) = ConversationSegmenter::JST.local(*args)

  def add(session, role, body, at)
    @n = (@n || 0) + 1
    Message.create!(source: "claude_ai", external_id: "dummy-#{@n}", session_id: session,
                    role:, body:, occurred_at: at)
  end

  def rebuild(now:, apply: true) = SegmentRebuilder.rebuild!(apply:, now:)

  setup do
    @now = jst(2026, 11, 5, 12)
    # 会話 A: 合図で閉じ、再開して、いまも続いている。会話 B: 1区切りだけ。
    add("A", "user", "はじめ", jst(2026, 11, 1, 9))
    add("A", "user", "おやすみなさい", jst(2026, 11, 1, 22))
    add("A", "assistant", "おやすみ", jst(2026, 11, 1, 22, 1))
    add("A", "user", "再開します", jst(2026, 11, 5, 11))
    add("A", "assistant", "どうぞ", jst(2026, 11, 5, 11, 1))
    add("B", "user", "ひとこと", jst(2026, 11, 2, 9))
  end

  test "dry-run は DB に書かず、報告だけ返す" do
    report = rebuild(now: @now, apply: false)
    assert_equal 0, Segment.count
    assert_equal 3, report.total
    assert_equal({ "end_phrase" => 1, "open" => 1, "gap" => 1 }, report.end_reasons)
    assert_equal 1, report.open_count
    assert_equal({ min: 1, median: 1.5, max: 2 }, report.per_session_stats)
    assert_equal 3, report.max_messages
    assert_equal 0, report.written
  end

  test "実書き込みで区切りを作る" do
    report = rebuild(now: @now)
    assert_equal 3, Segment.count
    assert_equal 3, report.written
    a1, a2 = Segment.where(session_id: "A").order(:started_at)
    assert_equal "end_phrase", a1.end_reason
    assert_equal "resume_phrase", a2.start_reason
    assert a2.resumed
    assert_equal a1, a2.continued_from
    assert_equal "open", a2.end_reason
    assert_equal Date.new(2026, 11, 5), a2.segment_date
    assert_nil a1.continued_from
  end

  test "合図のない末尾の区切りは、6時間以上たっていれば gap で閉じる" do
    rebuild(now: @now)
    assert_equal "gap", Segment.find_by!(session_id: "B").end_reason
  end

  test "閉じた区切りは更新しない（id も作成時刻も変わらない）" do
    rebuild(now: @now)
    closed = Segment.closed.pluck(:id, :created_at, :updated_at)
    add("A", "user", "続き", jst(2026, 11, 5, 11, 30))
    rebuild(now: @now)
    assert_equal closed.sort, Segment.closed.pluck(:id, :created_at, :updated_at).sort
  end

  test "open の区切りだけ、新しい発言で作り直して伸ばす" do
    rebuild(now: @now)
    open_id = Segment.find_by!(session_id: "A", end_reason: "open").id
    add("A", "user", "続き", jst(2026, 11, 5, 11, 30))
    rebuild(now: @now)

    a2 = Segment.where(session_id: "A").order(:started_at).last
    assert_not_equal open_id, a2.id
    assert_equal "open", a2.end_reason
    assert_equal "続き", a2.last_message.body
    assert_equal 3, Message.where(session_id: "A").where("occurred_at >= ?", a2.started_at).count
    assert_equal 2, Segment.where(session_id: "A").count
    assert_equal Segment.where(session_id: "A").order(:started_at).first, a2.continued_from
  end

  test "open の区切りは、時間がたって合図なしなら gap で閉じる" do
    rebuild(now: @now)
    rebuild(now: jst(2026, 11, 5, 18))
    a2 = Segment.where(session_id: "A").order(:started_at).last
    assert_equal "gap", a2.end_reason
  end

  test "返答待ちで open だった合図の区切りは、返答が入ると閉じる" do
    add("C", "user", "中断します", jst(2026, 11, 5, 10))
    rebuild(now: jst(2026, 11, 5, 11))
    assert_equal "open", Segment.find_by!(session_id: "C").end_reason

    add("C", "assistant", "了解です", jst(2026, 11, 5, 10, 1))
    rebuild(now: jst(2026, 11, 5, 11))
    c = Segment.find_by!(session_id: "C")
    assert_equal "end_phrase", c.end_reason
    assert_equal 2, c.last_message_id - c.first_message_id + 1
  end

  test "閉じた区切りの後ろの発言は、前の end_reason に応じた start_reason で始まる" do
    add("D", "user", "さようなら", jst(2026, 11, 1, 9))
    add("D", "assistant", "また", jst(2026, 11, 1, 9, 1))
    rebuild(now: @now)
    add("D", "user", "やあ", jst(2026, 11, 5, 9))
    rebuild(now: jst(2026, 11, 5, 9, 5))
    d = Segment.where(session_id: "D").order(:started_at).to_a
    assert_equal %w[ end_phrase open ], d.map(&:end_reason)
    assert_equal "after_end", d.last.start_reason
    assert_not d.last.resumed
  end

  test "dry-run の結果は実書き込みの結果と一致する" do
    dry = rebuild(now: @now, apply: false)
    real = rebuild(now: @now)
    assert_equal dry.end_reasons, real.end_reasons
    assert_equal dry.total, Segment.count
  end
end
