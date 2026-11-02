require "test_helper"

# ダミーの発言だけを使う。DBには触れない。
class Diary::QuoteRestorerTest < ActiveSupport::TestCase
  R = Diary::QuoteRestorer

  def at(minute) = Time.utc(2026, 11, 1, 10) + (minute * 60)
  def human(id, minute, text) = Diary::DecisionLinker::HumanMessage.new(id:, occurred_at: at(minute), text:)
  def item(quote, heading: "決定") = Diary::Item.new(heading:, text: "本文", quote:, chunk_index: 0)
  def call(quote, humans, bodies: {}) = R.call({ "決定" => [ item(quote) ] }, human_messages: humans, bodies:)
  def quote_of(result) = result.items["決定"].first.quote

  test "句読点の差を、原文の字面に戻す" do
    result = call("できるようになったら導入します", [ human(1, 0, "前置き。できるように、なったら、導入します。後ろ") ])
    assert_equal "できるように、なったら、導入します。", quote_of(result)
    assert_equal 1, result.restored
    assert_empty result.partial
  end

  test "すでに原文と同じ引用は変えない" do
    result = call("この方針にします。", [ human(1, 0, "この方針にします。") ])
    assert_equal [ 0, 1 ], [ result.restored, result.unchanged ]
  end

  test "文の途中で終わる引用は延ばさず、quote_partial に記録する" do
    result = call("用意することで", [ human(1, 0, "式目チェックを用意することで、会を成り立たせる。") ])
    assert_equal "用意することで、", quote_of(result)
    assert_equal [ "決定:0" ], result.partial
  end

  test "文の途中から始まる引用も quote_partial" do
    result = call("会を成り立たせる", [ human(1, 0, "式目チェックを用意することで、会を成り立たせる。") ])
    assert_equal [ "決定:0" ], result.partial
  end

  test "文頭から文末までの引用は partial にしない（改行区切りも）" do
    result = call("二つ目", [ human(1, 0, "一つ目です\n二つ目\n三つ目") ])
    assert_empty result.partial
  end

  test "複数の発言に一致するときは、DecisionLinker と同じ最も早い発言から採る" do
    humans = [ human(7, 10, "同じ、文です"), human(3, 5, "同じ文です。"), human(9, 5, "同じ　文です") ]
    assert_equal "同じ文です。", quote_of(call("同じ文です", humans))
  end

  test "どの発言にもなければ、モデルの引用のまま残して failed に記録する" do
    result = call("ない引用です", [ human(1, 0, "別の発言") ])
    assert_equal "ない引用です", quote_of(result)
    assert_equal({ "決定:0" => :not_found }, result.failed)
  end

  test "引用が空の項目は何もしない" do
    result = call("", [ human(1, 0, "別の発言") ])
    assert_equal [ "", {}, 0 ], [ quote_of(result), result.failed, result.restored ]
  end

  test "原文（bodies）の部分文字列にならない範囲は置き換えない" do
    result = call("この方針にします", [ human(1, 0, "この方針にします。") ], bodies: { 1 => "別の原文です" })
    assert_equal({ "決定:0" => :not_in_body }, result.failed)
    assert_equal "この方針にします", quote_of(result)
  end

  test "全角・半角の差は原文の字面に戻る" do
    assert_equal "ＡＢＣを使う。", quote_of(call("ABCを使う", [ human(1, 0, "ＡＢＣを使う。") ]))
  end
end
