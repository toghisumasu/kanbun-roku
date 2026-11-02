require "test_helper"

class Diary::CoverageTest < ActiveSupport::TestCase
  C = Diary::Coverage

  test "決定語（活用形を含む）を含む発言を数える" do
    texts = %w[ この方針にします。 Bでいきましょう 来週と決めた これで進めます 優先しますね 採用 決定項目 承認します よしとします ]
    assert_equal texts.size, C.count(texts)[:decision_words]
  end

  test "「お願いします」「ください」は決定語に入れない" do
    assert_equal 0, C.count([ "確認をお願いします", "見てください", "気にしている" ])[:decision_words]
  end

  test "「A:」の行を数える（箇条書き・全角・NFKC を許す）" do
    texts = [ "Q: どうする\nA: これにする", "- A: 案1", "Ａ：全角", "回答 A: は途中", "A案を採る" ]
    assert_equal 3, C.count(texts)[:a_lines]
  end

  test "決定語と「A:」の行は、別の数" do
    counts = C.count([ "Q: どうする\nA: 案2", "この方針にします", "ふつうの発言" ])
    assert_equal({ decision_words: 1, a_lines: 1 }, counts)
  end

  test "空でも動く" do
    assert_equal({ decision_words: 0, a_lines: 0 }, C.count([]))
  end
end
