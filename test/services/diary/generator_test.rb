require "test_helper"
require_relative "../../support/diary_helpers"

class Diary::GeneratorTest < ActiveSupport::TestCase
  include DiaryHelpers

  # 引用が人間の発言に含まれる、正しい A の出力。
  def good_output
    a_json(
      "人間の依頼・共有" => [ [ "設計の見直しを依頼した", "データベースの設計を見直したい" ] ],
      "決定" => [ [ "次の作業は来週にすると決めた", "次の作業は来週にします" ] ]
    )
  end

  def segment
    @segment ||= create_segment([
      [ "assistant", "前の話の返答です", -10 ],
      [ "user", "データベースの設計を見直したい。", 0 ],
      [ "assistant", "分けるのがよいと思います", 1 ],
      [ "user", "次の作業は来週にします。", 2 ]
    ])
  end

  def generate(client, **options) = Diary::Generator.call(segment, client:, detector: empty_detector, **options)

  test "A を呼んで、DiaryEntry・リンク・塊の記録を保存する" do
    client = FakeClient.new(response(good_output))
    result = generate(client)
    assert_equal :generated, result.status
    entry = result.entry
    assert_equal segment.id, entry.segment_id
    assert_equal [ "dummy-model", Diary::Prompts::A::PROMPT_VERSION, Diary::Rules::VERSION ], [ entry.model, entry.prompt_version, entry.rule_version ]
    assert_equal Date.new(2026, 11, 1), entry.entry_date
    assert_equal [ "次の作業は来週にすると決めた" ], entry.note["決定"].map { |i| i["本文"] }
    assert_equal({ "total" => 2, "pass" => 2, "fail" => 0 }, entry.validation["counts"].slice("total", "pass", "fail"))
    assert_equal({ "人間の依頼・共有:0" => "pass", "決定:0" => "pass" }, entry.validation["items"])
    chunk = DiaryChunk.find_by!(segment_id: segment.id)
    assert_equal [ "succeeded", 1, "sha256:dummydigest", "dummy-model", Diary::Prompts::A::PROMPT_VERSION ],
      [ chunk.status, chunk.attempts, chunk.model_digest, chunk.model, chunk.prompt_version ]
    assert_equal [ 1200, 300, 40_000 ], [ chunk.prompt_eval_count, chunk.eval_count, chunk.total_duration_ms ]
    assert_equal Diary::Generator.seed_for(segment.id, 0, 0), chunk.seed
    assert_equal good_output, chunk.raw_output
  end

  test "Ollama には、A の指示文・スキーマ・設定・人間の発言だけの入力を渡す。keep_alive や seed は呼び出し側" do
    client = FakeClient.new(response(good_output))
    generate(client)
    call = client.calls.first
    assert_equal Diary::Prompts::A::INSTRUCTION, call[:system]
    assert_equal Diary::Prompts::A::SCHEMA, call[:schema]
    assert_equal Diary::Prompts::A::OPTIONS, call[:options]
    assert_equal "[10:00] データベースの設計を見直したい。\n[10:02] 次の作業は来週にします。", call[:user]
    assert_not_includes call[:user], "分けるのが"
  end

  test "決定の項目から、人間の発言への source と、直前の assistant への候補リンクを付ける" do
    generate(FakeClient.new(response(good_output)))
    entry = DiaryEntry.find_by!(segment_id: segment.id)
    users = Message.where(session_id: segment.session_id, role: "user").order(:id).to_a
    assistants = Message.where(session_id: segment.session_id, role: "assistant").order(:id).to_a
    links = entry.diary_links.pluck(:item_key, :message_id, :link_kind)
    assert_includes links, [ "人間の依頼・共有:0", users[0].id, "source" ]
    assert_includes links, [ "決定:0", users[1].id, "source" ]
    assert_includes links, [ "決定:0", assistants[1].id, "preceding_assistant_candidate" ] # 時刻02の直前（01）の assistant
    assert_equal 3, links.size
  end

  test "冪等：同じ入力・版なら、2回目は何もしない（LLM を呼ばない）" do
    client = FakeClient.new(response(good_output))
    generate(client)
    again = generate(client)
    assert_equal :skipped_up_to_date, again.status
    assert_equal 1, client.calls.size
    assert_equal 1, DiaryEntry.count
  end

  test "再開：成功済みの塊の記録があれば、LLM を呼ばずに作り直せる" do
    client = FakeClient.new(response(good_output))
    generate(client)
    DiaryEntry.find_by!(segment_id: segment.id).tap { |e| e.diary_links.delete_all; e.destroy! }
    resumed = generate(client)
    assert_equal :generated, resumed.status
    assert_equal 1, client.calls.size, "塊の記録を再利用するので、呼び出しは増えない"
    assert_equal 1, DiaryChunk.count
  end

  test "規則の版だけが変わったときは、LLM を呼ばずに後処理だけやり直し、同じ行を更新する（注釈は残る）" do
    client = FakeClient.new(response(good_output))
    entry = generate(client).entry
    annotation = entry.annotations.create!(body: "後日考")
    entry.update!(rule_version: "old-version")
    redone = generate(client)
    assert_equal :generated, redone.status
    assert_equal 1, client.calls.size
    assert_equal entry.id, redone.entry.id
    assert_equal Diary::Rules::VERSION, redone.entry.reload.rule_version
    assert_equal [ annotation.id ], redone.entry.annotations.pluck(:id)
  end

  test "JSON が崩れたら、別の seed で1回だけ再試行する" do
    client = FakeClient.new(response("{\"決定\": ["), response(good_output))
    result = generate(client)
    assert_equal :generated, result.status
    assert_equal 2, client.calls.size
    assert_not_equal client.calls[0][:seed], client.calls[1][:seed]
    assert_equal Diary::Generator.seed_for(segment.id, 0, 0), client.calls[0][:seed]
    assert_equal Diary::Generator.seed_for(segment.id, 0, 1), client.calls[1][:seed]
    chunk = DiaryChunk.find_by!(segment_id: segment.id)
    assert_equal [ "succeeded", 2, nil ], [ chunk.status, chunk.attempts, chunk.error_kind ]
  end

  test "長さで打ち切られた出力も、別の seed で1回だけ再試行する" do
    client = FakeClient.new(response(good_output, done_reason: "length"), response(good_output))
    assert_equal :generated, generate(client).status
    assert_equal 2, client.calls.size
  end

  test "再試行しても崩れたら、その塊は failed。ダイアリーは作らない" do
    client = FakeClient.new(response("壊れた出力"), response("{\"決定\": ["))
    result = generate(client)
    assert_equal :failed, result.status
    assert_match(/塊0/, result.error)
    assert_equal 2, client.calls.size
    chunk = DiaryChunk.find_by!(segment_id: segment.id)
    assert_equal [ "failed", 2, "invalid_json" ], [ chunk.status, chunk.attempts, chunk.error_kind ]
    assert_equal "{\"決定\": [", chunk.raw_output, "崩れた出力も、そのまま残す"
    assert_equal 0, DiaryEntry.count
  end

  test "打ち切りが続いたら failed（error_kind は truncated）。構造が違う出力は schema" do
    truncated = FakeClient.new(response(good_output, done_reason: "length"))
    assert_equal :failed, generate(truncated).status
    assert_equal "truncated", DiaryChunk.find_by!(segment_id: segment.id).error_kind
    DiaryChunk.delete_all
    schema_error = FakeClient.new(response("[]"))
    assert_equal :failed, generate(schema_error).status
    assert_equal "schema", DiaryChunk.find_by!(segment_id: segment.id).error_kind
  end

  test "failed の座を再実行すると、前とは別の seed で試す" do
    first = FakeClient.new(response("壊れた"))
    generate(first)
    second = FakeClient.new(response(good_output))
    result = generate(second)
    assert_equal :generated, result.status
    assert_equal Diary::Generator.seed_for(segment.id, 0, 2), second.calls.first[:seed]
    assert_equal 3, DiaryChunk.find_by!(segment_id: segment.id).attempts
  end

  test "通信エラー（Unavailable）は、記録せずに上げる。ダイアリーは作らない" do
    client = FakeClient.new(Diary::OllamaClient::Unavailable.new("接続できません"))
    assert_raises(Diary::OllamaClient::Unavailable) { generate(client) }
    assert_equal 0, DiaryEntry.count
    assert_equal 0, DiaryChunk.where(status: "succeeded").count
  end

  test "open の座は作らない。人間の発言がない座も作らない（LLM を呼ばない）" do
    open_segment = create_segment([ [ "user", "依頼", 0 ], [ "assistant", "返答", 1 ] ], end_reason: "open")
    client = FakeClient.new(response(good_output))
    assert_equal :skipped_open, Diary::Generator.call(open_segment, client:, detector: empty_detector).status
    assistants_only = create_segment([ [ "assistant", "返答だけ", 0 ], [ "assistant", "続き", 1 ] ])
    assert_equal :skipped_no_input, Diary::Generator.call(assistants_only, client:, detector: empty_detector).status
    assert_equal 0, client.calls.size
  end

  test "複数の塊の座は、塊ごとに呼び、後処理で連結する。引用は、その塊の人間の発言と照合する" do
    specs = Array.new(8) { |i| [ "user", "漢字#{i}" * 40, i ] }
    multi = create_segment(specs)
    client = FakeClient.new(->(user) { response(a_json("人間の考え" => [ [ "考えを述べた", user.lines.first.sub(/\A\[[^\]]*\] /, "").chomp[0, 30] ] ])) })
    result = Diary::Generator.call(multi, client:, detector: empty_detector, limit: 600)
    assert_equal :generated, result.status
    chunks = DiaryChunk.where(segment_id: multi.id).order(:chunk_index)
    assert_operator chunks.size, :>=, 2
    assert_equal chunks.size, client.calls.size
    assert_equal chunks.size, result.entry.note["人間の考え"].size
    assert_equal (0...chunks.size).to_a, result.entry.note["人間の考え"].map { |i| i["chunk"] }
    assert_equal chunks.size, result.entry.validation["counts"]["pass"]
  end

  test "別の塊の発言からの引用は、逆の発言者でも入力にない引用でもなく、その塊では not_in_input になる" do
    specs = Array.new(8) { |i| [ "user", "漢字#{i}" * 40, i ] }
    multi = create_segment(specs)
    wrong = a_json("人間の考え" => [ [ "考え", "漢字7漢字7漢字7漢字7" ] ])
    right = a_json
    client = FakeClient.new(response(wrong), response(right))
    result = Diary::Generator.call(multi, client:, detector: empty_detector, limit: 600)
    assert_equal :generated, result.status
    assert_equal 1, result.entry.validation["counts"]["not_in_input"]
  end

  test "検証で不合格になった項目も保存する（判定は validation に残る。本文は validation に入れない）" do
    bad = a_json("人間の考え" => [ [ "考えた", "どこにも書かれていない長めの引用の文字列です" ] ], "決定" => [ [ "決めた", "" ] ])
    entry = generate(FakeClient.new(response(bad))).entry
    assert_equal({ "人間の考え:0" => "not_in_input", "決定:0" => "no_quote" }, entry.validation["items"])
    assert_equal 2, entry.validation["counts"]["fail"]
    assert_not_includes entry.validation.to_json, "どこにも書かれていない"
  end

  test "重複・再分類の件数と、リンクが付かなかった項目を validation に残す" do
    output = a_json(
      "決定" => [ [ "次の作業は来週にする方針を決めた", "確認してください" ], [ "別の決定", "次の作業は来週にします" ] ],
      "人間の考え" => [ [ "どこにもない引用の考え", "どこにもない長めの引用の文字列です" ] ]
    )
    entry = generate(FakeClient.new(response(output))).entry
    assert_equal 1, entry.validation["moved"]
    # 再分類した項目（人間の依頼・共有:0）の引用「確認してください」も、入力にないので、リンクが付かない
    assert_equal [ "人間の依頼・共有:0", "人間の考え:0" ], entry.validation["unmatched_links"].sort
    assert_equal({ "count" => 0, "by_heading" => {} }, entry.validation["dropped"])
  end

  test "seed は、座・塊・試行から決まる（再実行しても同じ。試行ごとに違う）" do
    assert_equal Diary::Generator.seed_for(5, 0, 0), Diary::Generator.seed_for(5, 0, 0)
    seeds = [ [ 5, 0, 0 ], [ 5, 0, 1 ], [ 5, 1, 0 ], [ 6, 0, 0 ] ].map { |a| Diary::Generator.seed_for(*a) }
    assert_equal 4, seeds.uniq.size
    assert(seeds.all? { |s| s.between?(0, 2_147_483_646) })
  end

  test "メッセージ（原本）は書き換えない" do
    segment # 先に座とメッセージを作る
    before = Message.order(:id).pluck(:body, :raw)
    generate(FakeClient.new(response(good_output)))
    assert_equal before, Message.order(:id).pluck(:body, :raw)
  end
end
