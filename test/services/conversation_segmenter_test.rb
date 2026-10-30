require "test_helper"

class ConversationSegmenterTest < ActiveSupport::TestCase
  Msg = Struct.new(:id, :role, :body, :occurred_at)

  def jst(*args) = ConversationSegmenter::JST.local(*args)

  def build(*specs)
    specs.each_with_index.map { |(role, body, at), i| Msg.new(i + 1, role, body, at) }
  end

  LATER = Time.utc(2027, 1, 1) # 十分に後の取り込み時刻

  # now の既定は最後の発言の1分後（末尾の区切りは閉じない）。
  def segment(*specs, now: nil, **options)
    messages = build(*specs)
    ConversationSegmenter.call(messages, now: now || messages.last.occurred_at + 1.minute, **options)
  end

  test "過去分は6時間以上の間隔で区切る" do
    r = segment(
      [ "user", "あ", jst(2026, 10, 1, 9) ],
      [ "assistant", "い", jst(2026, 10, 1, 14, 59) ],
      [ "user", "う", jst(2026, 10, 1, 20, 58) ],
      [ "user", "え", jst(2026, 10, 2, 3) ]
    )
    assert_equal [ 3, 1 ], r.map { |s| s.messages.size }
    assert_equal %w[ first gap ], r.map(&:start_reason)
    assert_equal %w[ gap open ], r.map(&:end_reason)
    assert_equal 0, r[1].continued_from_index
    assert_nil r[0].continued_from_index
  end

  test "過去分では終了の合図も再開の合図も効かない" do
    r = segment(
      [ "user", "おやすみなさい", jst(2026, 10, 1, 9) ],
      [ "user", "再開します", jst(2026, 10, 1, 9, 1) ]
    )
    assert_equal 1, r.size
  end

  test "終了の合図の直後の assistant の返答は閉じる側に含める" do
    r = segment(
      [ "user", "こちらからは以上です。", jst(2026, 11, 1, 22) ],
      [ "assistant", "お疲れさまでした", jst(2026, 11, 1, 22, 1) ],
      [ "assistant", "また", jst(2026, 11, 1, 22, 2) ],
      [ "user", "次の話", jst(2026, 11, 1, 22, 3) ]
    )
    assert_equal [ 3, 1 ], r.map { |s| s.messages.size }
    assert_equal %w[ end_phrase open ], r.map(&:end_reason)
    assert_equal "after_end", r[1].start_reason
    assert_not r[1].resumed?
  end

  test "終了の合図の集合は空白・句点・感嘆符の差を無視して全体一致する" do
    ConversationSegmenter::END_PHRASES.each do |phrase|
      r = segment(
        [ "user", " #{phrase}！ ", jst(2026, 11, 1, 22) ],
        [ "user", "続き", jst(2026, 11, 1, 22, 1) ]
      )
      assert_equal 2, r.size, phrase
    end
    assert_equal 1, segment(
      [ "user", "今日は中断しますと言った", jst(2026, 11, 1, 22) ],
      [ "user", "続き", jst(2026, 11, 1, 22, 1) ]
    ).size
  end

  test "assistant の発言は終了の合図にならない" do
    assert_equal 1, segment(
      [ "assistant", "さようなら", jst(2026, 11, 1, 22) ],
      [ "user", "続き", jst(2026, 11, 1, 22, 1) ]
    ).size
  end

  test "再開します: 直前が開いたままなら暗黙に閉じる" do
    r = segment(
      [ "user", "はじめ", jst(2026, 11, 1, 9) ],
      [ "assistant", "はい", jst(2026, 11, 1, 9, 1) ],
      [ "user", "再開します。", jst(2026, 11, 1, 9, 2) ]
    )
    assert_equal %w[ implicit open ], r.map(&:end_reason)
    assert_equal %w[ first resume_phrase ], r.map(&:start_reason)
    assert r[1].resumed?
    assert_equal 0, r[1].continued_from_index
  end

  test "再開します: 終了の合図の後は終了の区切りのまま新しい区切りを始める" do
    r = segment(
      [ "user", "中断します", jst(2026, 11, 1, 9) ],
      [ "assistant", "はい", jst(2026, 11, 1, 9, 1) ],
      [ "user", "再開 します", jst(2026, 11, 1, 9, 2) ]
    )
    assert_equal %w[ end_phrase open ], r.map(&:end_reason)
    assert_equal "resume_phrase", r[1].start_reason
  end

  test "再開します: 会話の最初なら continued_from は無い" do
    r = segment([ "user", "再開します", jst(2026, 11, 1, 9) ])
    assert r.first.resumed?
    assert_nil r.first.continued_from_index
  end

  test "10-30 以降は長い間隔があっても区切らない" do
    assert_equal 1, segment(
      [ "user", "あ", jst(2026, 11, 1, 9) ],
      [ "user", "い", jst(2026, 11, 2, 9) ]
    ).size
  end

  test "区切りの日付は開始時刻の日本時間の暦日" do
    # 2026-11-01 23:30 JST = 2026-11-01 14:30 UTC
    r = segment(
      [ "user", "あ", Time.utc(2026, 11, 1, 14, 30) ],
      [ "user", "い", Time.utc(2026, 11, 1, 16, 30) ] # 翌 01:30 JST、同じ区切り
    )
    assert_equal Date.new(2026, 11, 1), r.first.segment_date
    assert_equal 1, r.size
  end

  test "40文字を超える発言は、終了の合図の語を含んでも終了にならない" do
    long = "今日はここまでにしたいので" + "あ" * 30 + "中断します"
    assert_operator long.length, :>, 40
    assert_equal 1, segment(
      [ "user", long, jst(2026, 11, 1, 22) ],
      [ "user", "続き", jst(2026, 11, 1, 22, 1) ]
    ).size
  end

  test "終了の合図は40文字ちょうどまで長さの条件を満たす" do
    pad = " " * 100 # 前後の空白は長さに数えない
    assert_equal 2, segment(
      [ "user", "#{pad}おやすみなさい#{pad}", jst(2026, 11, 1, 22) ],
      [ "user", "続き", jst(2026, 11, 1, 22, 1) ]
    ).size
  end

  test "長い発言の「再開します」を含む文は再開にならない" do
    assert_equal 1, segment(
      [ "user", "はじめ", jst(2026, 11, 1, 9) ],
      [ "user", "では午後の作業を再開します、まずはテストから", jst(2026, 11, 1, 9, 1) ]
    ).size
  end

  test "境界（10-30 JST）をまたぐ区切りは分けない" do
    r = segment(
      [ "user", "あ", jst(2026, 10, 29, 20) ],
      [ "assistant", "い", jst(2026, 10, 29, 23, 59) ],
      [ "user", "う", jst(2026, 10, 30, 0, 1) ],
      [ "user", "え", jst(2026, 10, 30, 12) ]
    )
    assert_equal [ 4 ], r.map { |s| s.messages.size }
  end

  test "境界の前の6時間ルールは、境界の前の発言どうしにだけ効く" do
    r = segment(
      [ "user", "あ", jst(2026, 10, 29, 6) ],
      [ "user", "い", jst(2026, 10, 29, 12, 1) ], # 6時間超: 分ける
      [ "user", "う", jst(2026, 10, 30, 8) ]      # 境界以降: 間隔では分けない
    )
    assert_equal [ 1, 2 ], r.map { |s| s.messages.size }
  end

  test "開いた区切りは、新しい発言が入ると伸びる" do
    base = [
      [ "user", "あ", jst(2026, 11, 1, 9) ],
      [ "assistant", "い", jst(2026, 11, 1, 9, 1) ]
    ]
    before = segment(*base)
    assert_equal [ "open" ], before.map(&:end_reason)

    after = segment(*base, [ "user", "う", jst(2026, 11, 1, 9, 2) ])
    assert_equal [ 3 ], after.map { |s| s.messages.size }
    assert_equal [ "open" ], after.map(&:end_reason)
  end

  test "開いた区切りは、新しい発言で閉じる" do
    r = segment(
      [ "user", "あ", jst(2026, 11, 1, 9) ],
      [ "user", "さようなら", jst(2026, 11, 1, 9, 1) ],
      [ "assistant", "また", jst(2026, 11, 1, 9, 2) ]
    )
    assert_equal [ "end_phrase" ], r.map(&:end_reason)
  end

  test "開いた区切りの先頭以降だけで計算し直しても、全体で計算した結果と同じになる" do
    all = build(
      [ "user", "あ", jst(2026, 11, 1, 9) ],
      [ "user", "おやすみなさい", jst(2026, 11, 1, 10) ],
      [ "assistant", "はい", jst(2026, 11, 1, 10, 1) ],
      [ "user", "再開します", jst(2026, 11, 2, 9) ],
      [ "assistant", "どうぞ", jst(2026, 11, 2, 9, 1) ],
      [ "user", "続き", jst(2026, 11, 2, 9, 2) ]
    )
    full = ConversationSegmenter.call(all)
    open_segment = full.last
    assert_equal "open", open_segment.end_reason

    recomputed = ConversationSegmenter.call(all.drop_while { |m| m.id != open_segment.messages.first.id })
    assert_equal [ open_segment.messages.map(&:id) ], recomputed.map { |s| s.messages.map(&:id) }
    assert_equal open_segment.end_reason, recomputed.last.end_reason
    assert_equal open_segment.start_reason, "resume_phrase"
  end

  test "末尾が終了の合図で返答なし、6時間未満なら open" do
    r = segment(
      [ "user", "あ", jst(2026, 11, 1, 21) ],
      [ "user", "おやすみなさい", jst(2026, 11, 1, 22) ],
      now: jst(2026, 11, 2, 3, 59)
    )
    assert_equal [ "open" ], r.map(&:end_reason)
  end

  test "末尾が終了の合図で返答なし、6時間以上たてば end_phrase で閉じる" do
    r = segment(
      [ "user", "おやすみなさい", jst(2026, 11, 1, 22) ],
      now: jst(2026, 11, 2, 4)
    )
    assert_equal [ "end_phrase" ], r.map(&:end_reason)
  end

  test "終了の合図に返答があれば、取り込み直後でも end_phrase で閉じる" do
    r = segment(
      [ "user", "おやすみなさい", jst(2026, 11, 1, 22) ],
      [ "assistant", "おやすみなさい", jst(2026, 11, 1, 22, 1) ],
      now: jst(2026, 11, 1, 22, 2)
    )
    assert_equal [ "end_phrase" ], r.map(&:end_reason)
  end

  test "返答なしで open だった区切りは、返答が入ると計算し直して閉じる" do
    base = [ [ "user", "中断します", jst(2026, 11, 1, 22) ] ]
    now = jst(2026, 11, 1, 22, 5)
    assert_equal [ "open" ], segment(*base, now:).map(&:end_reason)

    r = segment(*base, [ "assistant", "了解です", jst(2026, 11, 1, 22, 1) ], now:)
    assert_equal [ "end_phrase" ], r.map(&:end_reason)
    assert_equal [ 2 ], r.map { |s| s.messages.size }
  end

  test "途中の区切りは、終了の合図で終わって返答がなくても閉じている" do
    r = segment(
      [ "user", "さようなら", jst(2026, 11, 1, 22) ],
      [ "user", "やっぱり続き", jst(2026, 11, 1, 22, 1) ],
      now: jst(2026, 11, 1, 22, 2)
    )
    assert_equal %w[ end_phrase open ], r.map(&:end_reason)
  end

  test "合図のない末尾の区切りは、最後の発言から6時間未満なら open" do
    r = segment([ "user", "あ", jst(2026, 11, 1, 9) ], now: jst(2026, 11, 1, 14, 59))
    assert_equal [ "open" ], r.map(&:end_reason)
  end

  test "合図のない末尾の区切りは、最後の発言から6時間以上たてば gap で閉じる" do
    r = segment(
      [ "user", "あ", jst(2026, 11, 1, 9) ],
      [ "assistant", "い", jst(2026, 11, 1, 9, 1) ],
      now: jst(2026, 11, 1, 15, 1)
    )
    assert_equal [ "gap" ], r.map(&:end_reason)
  end

  test "閉じた区切りの後ろから計算し直すとき、最初の start_reason は前の end_reason で決まる" do
    msg = [ [ "user", "あ", jst(2026, 11, 2, 9) ] ]
    assert_equal "gap", segment(*msg, previous_end_reason: "gap").first.start_reason
    assert_equal "after_end", segment(*msg, previous_end_reason: "end_phrase").first.start_reason
    assert_equal "resume_phrase", segment(*msg, previous_end_reason: "implicit").first.start_reason
    assert_equal "first", segment(*msg).first.start_reason
    assert_equal "resume_phrase",
      segment([ "user", "再開します", jst(2026, 11, 2, 9) ], previous_end_reason: "end_phrase").first.start_reason
  end
end
