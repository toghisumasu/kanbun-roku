# 日記の生成のテスト用の補助。ダミーデータだけを作る（実データは使わない）。
module DiaryHelpers
  BASE_TIME = Time.utc(2026, 11, 1, 1, 0) # 日本時間 10:00

  # specs: [[role, body, 分], ...]（BASE_TIME からの経過分）。座（segment）を作って返す。
  def create_segment(specs, session: "s-#{SecureRandom.hex(4)}", end_reason: "gap", raws: {})
    messages = specs.each_with_index.map do |(role, body, minute), i|
      Message.create!(source: "claude_ai", external_id: "#{session}-#{i}", session_id: session, role:, body:,
                      occurred_at: BASE_TIME + (minute * 60), raw: raws.fetch(i, {}))
    end
    Segment.create!(session_id: session, segment_date: Date.new(2026, 11, 1), first_message: messages.first, last_message: messages.last,
                    started_at: messages.first.occurred_at, ended_at: messages.last.occurred_at, start_reason: "first", end_reason:)
  end

  def empty_detector = ClaudePasteDetector.new([])

  # A の出力（JSON の文字列）。items: { 見出し => [[本文, 引用], ...] }
  def a_json(items = {})
    JSON.generate(Diary::Rules::HEADINGS.to_h do |heading|
      [ heading, items.fetch(heading, []).map { |text, quote| { "本文" => text, "引用" => quote } } ]
    end)
  end

  def response(content, done_reason: "stop")
    Diary::OllamaClient::Response.new(content:, done_reason:, prompt_eval_count: 1200, eval_count: 300, total_duration_ms: 40_000,
                                      prompt_eval_duration_ms: 5_000, eval_duration_ms: 35_000, thinking_chars: 0)
  end

  # 決まった応答を順に返す偽のクライアント。例外を渡すと、その例外を投げる。
  class FakeClient
    attr_reader :model, :calls

    def initialize(*responses, model: "dummy-model", digest: "sha256:dummydigest")
      @responses = responses
      @model = model
      @digest = digest
      @calls = []
    end

    def chat(system:, user:, schema:, options:, seed:)
      @calls << { system:, user:, schema:, options:, seed: }
      item = @responses.length > 1 ? @responses.shift : @responses.first
      raise item if item.is_a?(Exception)

      item.respond_to?(:call) ? item.call(user) : item
    end

    def model_digest = @digest
  end
end
