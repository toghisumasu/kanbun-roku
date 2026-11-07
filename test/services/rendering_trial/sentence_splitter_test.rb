require "test_helper"

# ダミーの文だけを使う。
class RenderingTrial::SentenceSplitterTest < ActiveSupport::TestCase
  S = RenderingTrial::SentenceSplitter

  test "「。」「！」「？」と改行で分け、記号は文の末尾に残す" do
    assert_equal [ "最初の文。", "次の文！", "三つ目の文？", "改行の前", "改行の後" ], S.call("最初の文。次の文！三つ目の文？改行の前\n改行の後")
  end

  test "区切りが続くときは1つにまとめる（記号だけの文を作らない）" do
    assert_equal [ "本当？！", "はい。" ], S.call("本当？！はい。")
    assert_equal [ "文。。。" ], S.call("文。。。")
  end

  test "空の文・空白だけ・記号だけの文は捨てる。前後の空白は除く" do
    assert_equal [], S.call("")
    assert_equal [], S.call(nil)
    assert_equal [], S.call(" \n \n。\n！？")
    assert_equal [ "文A。", "文B" ], S.call("  文A。 \n\n  文B  \r\n")
  end

  test "区切りのない本文は1文" do
    assert_equal [ "区切りのない本文" ], S.call("区切りのない本文")
  end

  test "「、」や半角のピリオド・感嘆符では分けない" do
    assert_equal [ "甲、乙. 丙!" ], S.call("甲、乙. 丙!")
  end
end
