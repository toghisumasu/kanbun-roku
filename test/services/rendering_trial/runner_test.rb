require "test_helper"

# LLM は呼ばない。偽の変換器を渡す。ダミーの文だけを使う。
class RenderingTrial::RunnerTest < ActiveSupport::TestCase
  Result = KanbunKa::KanbunTranslatorService::Result

  # 文（日本語）→ Result または例外を返す偽の変換器。呼ばれた文を記録する。
  class FakeTranslator
    attr_reader :calls

    def initialize(&block)
      @calls = []
      @block = block
    end

    def call(sentence)
      @calls << sentence
      @block.call(sentence)
    end
  end

  def item(date, key, body, segment_id: 1) = RenderingTrial::Targets::Item.new(date:, segment_id:, item_key: key, body:)

  def ok(hakubun: "甲乙", fallback: false, retried: false, parse_error: nil)
    Result.new(hakubun:, kunten: "甲[二]乙[一]", kakikudashi: "乙甲", skeleton: "骨格", fallback:, parse_error:, retried:)
  end

  # 呼ぶたびに1秒進む時計。
  def clock
    t = -1.0
    -> { t += 1.0 }
  end

  test "項目を文に分け、1文ずつ変換器に通す。日付ごとの項目数・文数と結果を返す" do
    translator = FakeTranslator.new { |_| ok }
    outcome = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "文A。文B。"), item("2026-11-01", "人間の考え:0", "文C"), item("2026-11-02", "決定:0", "文D") ],
                                        translator:, clock:).call
    assert_equal [ "文A。", "文B。", "文C", "文D" ], translator.calls
    assert_equal({ "2026-11-01" => { items: 2, sentences: 3 }, "2026-11-02" => { items: 1, sentences: 1 } }, outcome[:dates])
    assert_equal [ [ "2026-11-01", "決定:0", 1 ], [ "2026-11-01", "決定:0", 2 ], [ "2026-11-01", "人間の考え:0", 1 ], [ "2026-11-02", "決定:0", 1 ] ],
      outcome[:results].map { |r| [ r[:date], r[:item_key], r[:sentence_no] ] }
  end

  test "結果には原文（日本語）と骨格を入れない。白文・訓点・書き下しと各フラグ、秒数を入れる" do
    outcome = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "原文のダミー") ], translator: FakeTranslator.new { |_| ok(retried: true) }, clock:).call
    row = outcome[:results].first
    assert_equal({ fallback: false, retried: true, hakubun_kind: "kanji_only", parse_error: nil, error: nil, seconds: 1.0,
                   hakubun: "甲乙", kunten: "甲[二]乙[一]", kakikudashi: "乙甲" }, row.slice(:fallback, :retried, :hakubun_kind, :parse_error, :error, :seconds, :hakubun, :kunten, :kakikudashi))
    assert_not_includes row.to_json, "原文のダミー"
    assert_not_includes row.to_json, "骨格"
  end

  test "白文の種類：漢字と句読点だけ / 空 / それ以外" do
    kinds = { "甲乙。" => "kanji_only", "" => "empty", "かな交じり" => "other", "甲 乙" => "other" }
    kinds.each do |hakubun, expected|
      row = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "文") ], translator: FakeTranslator.new { |_| ok(hakubun:) }, clock:).call[:results].first
      assert_equal expected, row[:hakubun_kind], hakubun.inspect
    end
  end

  test "parse_error は、理由の本文を捨てて、種類（クラス名）だけを持つ" do
    translator = FakeTranslator.new { |_| ok(parse_error: "UnknownCharacters: 辞書にない字 蜜柑 を含む") }
    row = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "文") ], translator:, clock:).call[:results].first
    assert_equal "UnknownCharacters", row[:parse_error]
    assert_not_includes row.to_json, "蜜柑"
  end

  test "変換器が例外を出した文は、例外のクラス名だけを記録して続ける（メッセージは持たない）" do
    translator = FakeTranslator.new { |s| s == "文B" ? raise(Net::ReadTimeout, "本文入りのメッセージ") : ok }
    outcome = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "文A\n文B\n文C") ], translator:, clock:).call
    assert_equal [ nil, "Net::ReadTimeout", nil ], outcome[:results].map { |r| r[:error] }
    assert_not_includes outcome[:results].to_json, "本文入りのメッセージ"
    assert_equal 3, outcome[:dates]["2026-11-01"][:sentences]
  end

  test "日付が終わるたびに、ブロックへそこまでの結果を渡す。全体の所要時間を返す" do
    seen = []
    outcome = RenderingTrial::Runner.new([ item("2026-11-01", "決定:0", "文A"), item("2026-11-02", "決定:0", "文B") ],
                                        translator: FakeTranslator.new { |_| ok }, clock:).call { |dates, results, _| seen << [ dates.keys, results.size ] }
    assert_equal [ [ [ "2026-11-01" ], 1 ], [ [ "2026-11-01", "2026-11-02" ], 2 ] ], seen
    assert_operator outcome[:total_seconds], :>, 0
  end

  test "plan は LLM を呼ばず、日付ごとの項目数・文数・見出し別の項目数だけを数える" do
    plan = RenderingTrial::Runner.plan([ item("2026-11-01", "決定:0", "文A。文B"), item("2026-11-01", "人間の考え:0", "文C"), item("2026-11-02", "決定:1", "文D") ])
    assert_equal({ items: 2, sentences: 3, by_heading: { "決定" => 1, "人間の考え" => 1 } }, plan["2026-11-01"])
    assert_equal({ items: 1, sentences: 1, by_heading: { "決定" => 1 } }, plan["2026-11-02"])
  end
end
