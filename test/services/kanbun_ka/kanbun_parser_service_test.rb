require "test_helper"

# 複製元（kanbun-ka、コミット 65bb176）の spec/services/kanbun_parser_service_spec.rb を minitest に移したもの。
# MeCab・Ollama は使わない（白文から訓点・書き下しを作る Racc パーサーの部分だけ）。
class KanbunKa::KanbunParserServiceTest < ActiveSupport::TestCase
  def call(text) = KanbunKa::KanbunParserService.call(text)

  test "訓点付き漢文（返り点）を返す" do
    result = call("我読漢文")
    assert_equal "我読[二]漢文[一]", result[:kunten]
    assert_equal :parsed, result[:status]
    assert_nil result[:error]
  end

  test "レ点・一二三点も付く" do
    assert_equal "不[レ]読[レ]書", call("不読書")[:kunten]
    assert_equal "不[三]必読[二]漢文[一]", call("不必読漢文")[:kunten]
  end

  test "注記つき漢文（正本）を返す" do
    assert_equal "我読［＃二］漢文［＃一］", call("我読漢文")[:kunten_aozora]
  end

  test "書き下しは返り点の順に並べる（送り仮名は未付与）" do
    assert_equal "我漢文読", call("我読漢文")[:kakikudashi]
  end

  test "再読文字は 2 度読む" do
    assert_equal "未だ知ず", call("未知")[:kakikudashi]
  end

  test "前後の空白は無視する" do
    assert_equal "不[レ]学", call(" 不学\n")[:kunten]
  end

  test "辞書にない字を含むときは白文をそのまま返し、理由を添える" do
    result = call("我食蜜柑")
    assert_equal :unparsed, result[:status]
    assert_equal "我食蜜柑", result[:kunten]
    assert_equal "我食蜜柑", result[:kakikudashi]
    assert_includes result[:error], "UnknownCharacters"
    assert_includes result[:error], "蜜柑"
  end

  test "文法外の語順のときも例外にしない" do
    result = call("花開鳥")
    assert_equal :unparsed, result[:status]
    assert_equal "花開鳥", result[:kunten]
    assert_includes result[:error], "ParseError"
  end

  test "空文字でも例外にしない" do
    assert_equal :unparsed, call("")[:status]
  end
end
