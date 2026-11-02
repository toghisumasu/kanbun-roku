require "test_helper"

class Diary::OllamaClientTest < ActiveSupport::TestCase
  Client = Diary::OllamaClient

  def transport(responses)
    calls = []
    callable = lambda do |method, path, body|
      calls << { method:, path:, body: }
      result = responses.fetch(path)
      raise result if result.is_a?(Exception)

      result
    end
    [ callable, calls ]
  end

  def chat_ok = [ 200, { "message" => { "content" => "{}" }, "done_reason" => "stop", "prompt_eval_count" => 1200, "eval_count" => 300,
                         "total_duration" => 50_400_000_000, "prompt_eval_duration" => 8_000_000_000, "eval_duration" => 42_000_000_000 } ]

  def chat(client, seed: 7) = client.chat(system: "指示", user: "入力", schema: { type: "object" }, options: { num_ctx: 16_384, temperature: 0.2 }, seed:)

  test "chat は、JSON スキーマ・思考なし・keep_alive 30分・seed・設定を送る" do
    callable, calls = transport("/api/chat" => chat_ok)
    chat(Client.new(base_url: "http://ollama.test", model: "m", transport: callable))
    body = calls.first[:body]
    assert_equal :post, calls.first[:method]
    assert_equal "m", body[:model]
    assert_equal false, body[:stream]
    assert_equal false, body[:think]
    assert_equal "30m", body[:keep_alive]
    assert_equal({ type: "object" }, body[:format])
    assert_equal({ num_ctx: 16_384, temperature: 0.2, seed: 7 }, body[:options])
    assert_equal [ { role: "system", content: "指示" }, { role: "user", content: "入力" } ], body[:messages]
  end

  test "応答のナノ秒はミリ秒にして返す" do
    callable, = transport("/api/chat" => chat_ok)
    response = chat(Client.new(base_url: "http://ollama.test", model: "m", transport: callable))
    assert_equal [ "{}", "stop", 1200, 300 ], [ response.content, response.done_reason, response.prompt_eval_count, response.eval_count ]
    assert_equal [ 50_400, 8_000, 42_000 ], [ response.total_duration_ms, response.prompt_eval_duration_ms, response.eval_duration_ms ]
  end

  test "Ollama がエラーを返したら ApiError（再試行しても直らない）" do
    callable, = transport("/api/chat" => [ 200, { "error" => "model not found" } ])
    assert_raises(Client::ApiError) { chat(Client.new(base_url: "http://ollama.test", model: "m", transport: callable)) }
    callable, = transport("/api/chat" => [ 500, {} ])
    assert_raises(Client::ApiError) { chat(Client.new(base_url: "http://ollama.test", model: "m", transport: callable)) }
  end

  test "接続できない・時間切れは Unavailable（再試行してよい）で、そのまま上がる" do
    callable, = transport("/api/chat" => Client::Unavailable.new("接続できません"))
    assert_raises(Client::Unavailable) { chat(Client.new(base_url: "http://ollama.test", model: "m", transport: callable)) }
  end

  test "model_digest は /api/tags から、名前（または :latest 付き）で探す。1回だけ取る" do
    tags = [ 200, { "models" => [ { "name" => "other:latest", "model" => "other:latest", "digest" => "aaa" },
                                  { "name" => "m:latest", "model" => "m:latest", "digest" => "bbb" } ] } ]
    callable, calls = transport("/api/tags" => tags)
    client = Client.new(base_url: "http://ollama.test", model: "m", transport: callable)
    assert_equal "bbb", client.model_digest
    assert_equal "bbb", client.model_digest
    assert_equal 1, calls.size
    assert_equal :get, calls.first[:method]
  end

  test "model_digest は、モデルが見つからなければ nil" do
    callable, = transport("/api/tags" => [ 200, { "models" => [] } ])
    assert_nil Client.new(base_url: "http://ollama.test", model: "m", transport: callable).model_digest
  end

  test "from_env は、OLLAMA_API_BASE が無ければ ConfigurationError。モデルは DIARY_MODEL（既定 qwen3-14b-16k）" do
    assert_raises(Client::ConfigurationError) { Client.from_env({}) }
    assert_raises(Client::ConfigurationError) { Client.from_env({ "OLLAMA_API_BASE" => "" }) }
    assert_equal "qwen3-14b-16k", Client.from_env({ "OLLAMA_API_BASE" => "http://ollama.test" }).model
    assert_equal "other", Client.from_env({ "OLLAMA_API_BASE" => "http://ollama.test", "DIARY_MODEL" => "other" }).model
  end

  test "接続先は、コードに固定していない" do
    source = File.read(Rails.root.join("app/services/diary/ollama_client.rb"))
    refute_match(/localhost|127\.0\.0\.1|11434/, source)
  end
end
