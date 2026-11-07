require "test_helper"

# ダミーの結果だけを使う。白文・訓点・書き下しは集計に使わず、画面にも出さない。
class RenderingTrial::ReportTest < ActiveSupport::TestCase
  def row(date, no, **fields)
    { "date" => date, "segment_id" => 1, "item_key" => "決定:0", "sentence_no" => no, "fallback" => false, "retried" => false,
      "hakubun_kind" => "kanji_only", "parse_error" => nil, "error" => nil, "seconds" => 2.0,
      "hakubun" => "秘密の白文", "kunten" => "秘密の訓点", "kakikudashi" => "秘密の書き下し" }.merge(fields.transform_keys(&:to_s))
  end

  def data
    { "meta" => { "generated_at" => "2026-11-08T00:00:00+09:00", "model" => "qwen3:8b", "prompt_version" => "A-x", "rule_version" => "r-x", "finished" => true,
                  "total_seconds" => 36.0, "dates" => { "2026-11-01" => { "items" => 2, "sentences" => 4 }, "2026-11-02" => { "items" => 1, "sentences" => 2 } } },
      "results" => [
        row("2026-11-01", 1), row("2026-11-01", 2, fallback: true, retried: true, hakubun_kind: "other", parse_error: "UnknownCharacters"),
        row("2026-11-01", 3, parse_error: "ParseError", seconds: 4.0), row("2026-11-01", 4, error: "Net::ReadTimeout", fallback: nil, hakubun_kind: nil, seconds: 6.0),
        row("2026-11-02", 1, hakubun_kind: "empty", parse_error: "ParseError"), row("2026-11-02", 2)
      ] }
  end

  test "日付別と全体の件数を数える" do
    table = RenderingTrial::Report.call(JSON.parse(JSON.generate(data)))
    day1 = table["2026-11-01"]
    assert_equal [ 2, 4 ], [ day1.items, day1.sentences ]
    assert_equal [ 2, 1 ], [ day1.skeleton, day1.fallback ] # 実行エラーの文は数えない
    assert_equal [ 2, 1, 1, 0 ], [ day1.kanji_only, day1.retried, day1.other_hakubun, day1.empty_hakubun ]
    assert_equal [ 1, 2, { "UnknownCharacters" => 1, "ParseError" => 1 } ], [ day1.parsed, day1.parse_error, day1.parse_error_kinds ]
    assert_equal [ 1, { "Net::ReadTimeout" => 1 }, 14.0 ], [ day1.errors, day1.error_kinds, day1.seconds ]
    all = table["全体"]
    assert_equal [ 3, 6, 4, 1 ], [ all.items, all.sentences, all.skeleton, all.fallback ]
    assert_equal [ 3, 2, 3, 1 ], [ all.kanji_only, all.other_hakubun, all.parse_error, all.errors ]
    assert_equal [ 0, 1, 1 ], [ day1.empty_hakubun, table["2026-11-02"].empty_hakubun, all.empty_hakubun ]
  end

  test "画面に出す行には、本文（白文・訓点・書き下し）を含めない。件数と秒数だけ" do
    text = RenderingTrial::Report.lines(JSON.parse(JSON.generate(data))).join("\n")
    assert_includes text, "全体"
    assert_includes text, "骨格あり 4 / 骨格なし（fallback）1"
    assert_includes text, "parse_error 3（ParseError=2 / UnknownCharacters=1）"
    assert_includes text, "実行エラー 1（Net::ReadTimeout=1）"
    assert_includes text, "全体の所要時間 36.0 秒"
    %w[ 秘密の白文 秘密の訓点 秘密の書き下し ].each { |secret| assert_not_includes text, secret }
  end

  test "途中までの結果（finished が false）はそう表示する" do
    partial = JSON.parse(JSON.generate(data))
    partial["meta"]["finished"] = false
    assert_includes RenderingTrial::Report.lines(partial).first, "途中まで"
  end

  test "latest_file は、名前が最も新しいファイルを選ぶ" do
    Dir.mktmpdir do |dir|
      %w[ rendering-trial-20261107.json rendering-trial-20261109.json rendering-trial-20261108.json other.json ].each { |name| File.write(File.join(dir, name), "{}") }
      assert_equal File.join(dir, "rendering-trial-20261109.json"), RenderingTrial::Report.latest_file(dir)
      assert_nil RenderingTrial::Report.latest_file(File.join(dir, "none"))
    end
  end
end
