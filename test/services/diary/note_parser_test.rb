require "test_helper"
require_relative "../../support/diary_helpers"

class Diary::NoteParserTest < ActiveSupport::TestCase
  include DiaryHelpers

  P = Diary::NoteParser

  test "正しい JSON は、見出しごとの Item になる（chunk_index を付ける）" do
    notes = P.call(a_json("決定" => [ [ "方針を決めた", "この方針にします" ] ], "未解決" => [ [ "課題", "どうしよう" ] ]), chunk_index: 2)
    assert_equal Diary::Rules::HEADINGS, notes.keys
    assert_equal [ Diary::Item.new(heading: "決定", text: "方針を決めた", quote: "この方針にします", chunk_index: 2) ], notes["決定"]
    assert_equal [], notes["人間の考え"]
  end

  test "空の配列でよい" do
    assert_equal [ [], [], [], [] ], P.call(a_json).values
  end

  test "JSON として解析できなければ invalid_json" do
    error = assert_raises(P::ParseError) { P.call("{\"決定\": [") }
    assert_equal :invalid_json, error.kind
    assert_equal :invalid_json, assert_raises(P::ParseError) { P.call("") }.kind
  end

  test "構造が違えば schema（最上位・見出しの欠落・配列でない・文字列でない・上限超え）" do
    assert_equal :schema, assert_raises(P::ParseError) { P.call("[]") }.kind
    missing = JSON.generate(Diary::Rules::HEADINGS.drop(1).to_h { |h| [ h, [] ] })
    assert_equal :schema, assert_raises(P::ParseError) { P.call(missing) }.kind
    not_array = JSON.generate(Diary::Rules::HEADINGS.to_h { |h| [ h, "なし" ] })
    assert_equal :schema, assert_raises(P::ParseError) { P.call(not_array) }.kind
    bad_item = JSON.generate(Diary::Rules::HEADINGS.to_h { |h| [ h, [ { "本文" => 1, "引用" => "x" } ] ] })
    assert_equal :schema, assert_raises(P::ParseError) { P.call(bad_item) }.kind
    no_quote_key = JSON.generate(Diary::Rules::HEADINGS.to_h { |h| [ h, [ { "本文" => "x" } ] ] })
    assert_equal :schema, assert_raises(P::ParseError) { P.call(no_quote_key) }.kind
    too_many = a_json("未解決" => Array.new(Diary::Rules::MAX_ITEMS.fetch("未解決") + 1) { |i| [ "本文#{i}", "引用#{i}" ] })
    assert_equal :schema, assert_raises(P::ParseError) { P.call(too_many) }.kind
  end

  test "余分なキーは無視する" do
    data = JSON.parse(a_json("決定" => [ [ "本文", "引用" ] ])).merge("余分" => [ 1 ])
    data["決定"][0]["種別"] = "判断"
    assert_equal 1, P.call(JSON.generate(data))["決定"].size
  end
end
