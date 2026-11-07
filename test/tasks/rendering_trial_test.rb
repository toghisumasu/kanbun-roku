require "test_helper"
require_relative "../support/diary_helpers"
require_relative "../support/rake_helpers"

# ダミーの日記だけを使う。LLM は呼ばない（APPLY なし）。ファイルは一時ディレクトリにだけ作る。
class RenderingTrialTaskTest < ActiveSupport::TestCase
  include DiaryHelpers
  include RakeHelpers

  def item(heading, text) = Diary::Item.new(heading:, text:, quote: "", chunk_index: 0)

  setup do
    segment = create_segment([ [ "user", "ダミー", 0 ], [ "assistant", "返答", 1 ] ])
    segment.update!(segment_date: Date.new(2026, 11, 1))
    items = Diary::Rules::HEADINGS.to_h { |h| [ h, [] ] }.merge("決定" => [ item("決定", "文A。文B。") ], "人間の考え" => [ item("人間の考え", "文C") ])
    Diary::Assembler.call(segment:, model: "dummy-model", input_digest: "x", items:, validation: {}, links: [])
  end

  test "ドライラン（既定）：日付ごとの項目数・文数を出し、ファイルは作らない。LLM は呼ばない" do
    before = Dir[Rails.root.join("data", "rendering-trial-*.json")].sort
    result = run_rake("rendering_trial:run", DATES: "2026-11-01,2026-11-09")
    assert_not result.aborted, result.err
    assert_includes result.out, "ドライラン（LLM は呼ばない）"
    assert_includes result.out, "2026-11-01: 項目 2（決定 1 / 人間の考え 1）/ 文 3"
    assert_includes result.out, "2026-11-09: 項目 0（該当する日記がない）"
    assert_includes result.out, "合計: 項目 2 / 文 3"
    assert_equal before, Dir[Rails.root.join("data", "rendering-trial-*.json")].sort
    assert_not_includes result.out, "文A"
  end

  test "DATES がない・日付の形が違うときは止まる" do
    [ {}, { DATES: " " }, { DATES: "2026/11/01" }, { DATES: "2026-11-01,あした" } ].each do |env|
      result = run_rake("rendering_trial:run", env)
      assert result.aborted, env.inspect
      assert_not_empty result.err, env.inspect
    end
  end

  test "report：FILE の結果を、件数と秒数だけで集計する（本文は出さない）" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rendering-trial-20261108.json")
      row = { "date" => "2026-11-01", "segment_id" => 1, "item_key" => "決定:0", "sentence_no" => 1, "fallback" => false, "retried" => false,
              "hakubun_kind" => "kanji_only", "parse_error" => nil, "error" => nil, "seconds" => 1.5, "hakubun" => "秘密", "kunten" => "秘密", "kakikudashi" => "秘密" }
      File.write(path, JSON.generate({ "meta" => { "generated_at" => "t", "model" => "m", "prompt_version" => "p", "rule_version" => "r", "finished" => true,
                                                    "total_seconds" => 1.5, "dates" => { "2026-11-01" => { "items" => 1, "sentences" => 1 } } }, "results" => [ row ] }))
      result = run_rake("rendering_trial:report", FILE: path)
      assert_not result.aborted, result.err
      assert_includes result.out, "項目 1 / 文 1"
      assert_includes result.out, "訓点・書き下しあり 1 / parse_error 0"
      assert_not_includes result.out, "秘密"
    end
  end

  test "report：ファイルがなければ止まる" do
    result = run_rake("rendering_trial:report", FILE: "/nonexistent/rendering-trial-x.json")
    assert result.aborted
  end
end
