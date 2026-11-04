require "test_helper"

# ダミーの validation だけを使う。DBには触れない。
class Diary::QuoteRestoreSummaryTest < ActiveSupport::TestCase
  S = Diary::QuoteRestoreSummary
  Entry = Struct.new(:validation)

  def entry(restored, unchanged, failed, partial)
    Entry.new({ "quote_restore" => { "restored" => restored, "unchanged" => unchanged, "failed" => failed, "partial" => partial } })
  end

  test "各件数は座の合計。置き換えた座の数は restored が1以上の座だけ数える" do
    s = S.call([ entry(2, 5, 1, 3), entry(0, 4, 0, 0), entry(1, 0, 2, 1) ])
    assert_equal 3, s.restored
    assert_equal 2, s.restored_segments
    assert_equal 9, s.unchanged
    assert_equal 3, s.failed
    assert_equal 4, s.partial
  end

  test "行の書式" do
    assert_equal "引用の原文化: 置き換えた 3（2座） / 変わらず 9 / 置き換えできず 3 / 一部だけの引用 4",
                 S.line([ entry(2, 5, 1, 3), entry(0, 4, 0, 0), entry(1, 0, 2, 1) ])
  end

  test "quote_restore のない座（導入前）や空の validation は0として数える。座がなくても動く" do
    s = S.call([ Entry.new({}), Entry.new(nil), entry(1, 1, 0, 0) ])
    assert_equal [ 1, 1, 1, 0, 0 ], [ s.restored, s.restored_segments, s.unchanged, s.failed, s.partial ]
    assert_equal "引用の原文化: 置き換えた 0（0座） / 変わらず 0 / 置き換えできず 0 / 一部だけの引用 0", S.line([])
  end
end
