require "json"
require "net/http"
require "uri"

module Diary
  # Ollama（ローカル）の /api/chat と /api/tags を呼ぶ、薄いクライアント。
  # JSON スキーマ（format）、思考なし（think: false）、keep_alive（30分）、seed を指定する必要があり、
  # RubyLLM のようなラッパーでは扱いにくいので、自前にしている。
  #
  # 接続先は環境変数 OLLAMA_API_BASE（コードには固定しない。公開リポジトリのため）。モデルは DIARY_MODEL。
  # 通信は transport（呼び出せるもの）に差し替えられる。テストでは、ネットワークを使わない。
  # transport.call(method, path, body) → [HTTPステータス, 解析済みのJSON]
  class OllamaClient
    class Error < StandardError; end
    class ConfigurationError < Error; end
    # 接続できない・時間切れ。再試行してよい。
    class Unavailable < Error; end
    # Ollama がエラーを返した（モデルが無い、など）。再試行しても直らない。
    class ApiError < Error; end

    KEEP_ALIVE = "30m"
    DEFAULT_MODEL = "qwen3-14b-16k"
    NETWORK_ERRORS = [ Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, EOFError, Net::OpenTimeout, Net::ReadTimeout ].freeze

    Response = Struct.new(:content, :done_reason, :prompt_eval_count, :eval_count, :total_duration_ms,
                          :prompt_eval_duration_ms, :eval_duration_ms, :thinking_chars, keyword_init: true)

    attr_reader :model

    def self.from_env(env = ENV)
      base_url = env["OLLAMA_API_BASE"].to_s
      raise ConfigurationError, "OLLAMA_API_BASE が設定されていません" if base_url.empty?

      new(base_url:, model: env.fetch("DIARY_MODEL", DEFAULT_MODEL))
    end

    def initialize(base_url:, model:, transport: nil, read_timeout: 900)
      @base_url = base_url
      @model = model
      @read_timeout = read_timeout
      @transport = transport || method(:http_request)
    end

    # options には Prompts::A::OPTIONS を渡す。seed は呼び出しごとに決める。
    def chat(system:, user:, schema:, options:, seed:)
      body = {
        model: @model, stream: false, think: false, format: schema, keep_alive: KEEP_ALIVE,
        messages: [ { role: "system", content: system }, { role: "user", content: user } ],
        options: options.merge(seed:)
      }
      status, json = @transport.call(:post, "/api/chat", body)
      raise ApiError, "Ollama がエラーを返しました: #{json["error"] || status}" if status >= 400 || json["error"]

      Response.new(
        content: json.dig("message", "content").to_s, done_reason: json["done_reason"],
        prompt_eval_count: json["prompt_eval_count"], eval_count: json["eval_count"],
        total_duration_ms: nanoseconds_to_ms(json["total_duration"]), prompt_eval_duration_ms: nanoseconds_to_ms(json["prompt_eval_duration"]),
        eval_duration_ms: nanoseconds_to_ms(json["eval_duration"]), thinking_chars: json.dig("message", "thinking").to_s.size
      )
    end

    # /api/tags から、このモデルの digest を取る。見つからなければ nil。同じ名前のモデルが入れ替わったかを見るための記録用で、
    # 冪等の鍵には含めない。
    def model_digest
      return @model_digest if defined?(@model_digest)

      status, json = @transport.call(:get, "/api/tags", nil)
      raise ApiError, "/api/tags がエラーを返しました: #{status}" if status >= 400

      names = [ @model, "#{@model}:latest" ]
      entry = Array(json["models"]).find { |m| names.include?(m["name"]) || names.include?(m["model"]) }
      @model_digest = entry && entry["digest"]
    end

    private

    def nanoseconds_to_ms(value) = value && (value / 1_000_000.0).round

    def http_request(method, path, body)
      uri = URI.join(@base_url, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = @read_timeout
      request = method == :post ? Net::HTTP::Post.new(uri, "Content-Type" => "application/json") : Net::HTTP::Get.new(uri)
      request.body = JSON.generate(body) if body
      response = http.request(request)
      [ response.code.to_i, response.body.to_s.empty? ? {} : JSON.parse(response.body) ]
    rescue *NETWORK_ERRORS => e
      raise Unavailable, "Ollama に接続できません（#{e.class}）"
    rescue JSON::ParserError
      raise ApiError, "Ollama の応答が JSON ではありません"
    end
  end
end
