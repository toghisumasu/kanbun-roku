# 1つの区切りの発言列を、曽良モードの入力（塊）に整える。DBには触れない純粋な関数。
# 入力は role / body に答える発言の列（区切りの順）。出力は塊の列で、発言の境界で分ける。
#
# 前処理:
# - コードブロックと長い引用は「（省略）」に置き換える（user・assistant とも）。
# - user は全文、assistant は先頭 ASSISTANT_HEAD_CHARS 文字だけ残し、切った箇所に「…（以下略）」を付ける。
# - 前処理後も単独で INPUT_LIMIT を超える発言は、先頭と末尾を残し、間を「（中略）」にする。
#
# トークン数は文字種別の式で見積もる。重みは claude.ai エクスポートの実データ30区間
# （Ollama qwen3-14b の prompt_eval_count）で較正した。根拠は下の定数のコメントを見ること。
# 実データでの塊数・削減率は `bin/rails segments:chunk_report`（読み取りのみ）で確かめる。
class SegmentChunker
  CONTEXT = 16_384
  # 出力（思考なし）の余裕。
  OUTPUT_RESERVE = 2_000
  # チャットテンプレートの特殊トークンなど、指示文と本文の外にある分。
  TEMPLATE_RESERVE = 100

  # 文字あたりのトークン数（日本語の漢字 / その他の非ASCII（かな・全角記号など）/ ASCII）。
  # 実測30件への最小二乗の当てはめ（漢字1.38・その他0.51・ASCII0.22）より高めに置いた。
  # ASCII はコード・URLの量で実測の振れが大きい（0.2〜0.5）ため、特に安全側に寄せている。
  HAN_WEIGHT = 1.4
  OTHER_WEIGHT = 0.6
  ASCII_WEIGHT = 0.4
  # 較正した式で、実測を下回った区間が出ないようにする係数。
  # 係数1.0では30件中1件で最大6.5%の過小。1.15で全件が実測以上（最小で約1.08倍）。
  SAFETY = 1.15

  ASSISTANT_HEAD_CHARS = 600
  # 連続する引用行（> で始まる行）の合計がこの文字数を超えたら省略する。
  QUOTE_MAX_CHARS = 300

  OMITTED = "（省略）".freeze
  TRUNCATED_MARK = "…（以下略）".freeze
  MIDDLE_MARK = "（中略）".freeze
  SEPARATOR = "\n\n".freeze
  LABELS = { "user" => "【人間】", "assistant" => "【Claude】" }.freeze

  CODE_BLOCK = /^[ \t]*```[^\n]*\n.*?^[ \t]*```[ \t]*$/m
  UNCLOSED_CODE_BLOCK = /^[ \t]*```[^\n]*\n.*\z/m
  QUOTE_RUN = /(?:^[ \t]*>[^\n]*(?:\n|\z))+/

  Chunk = Struct.new(:items, :text, :tokens, keyword_init: true)
  # index: 入力の発言列での位置。marks: この発言に入れた印（:omitted / :truncated / :middle）。
  Item = Struct.new(:index, :role, :text, :marks, keyword_init: true)
  Result = Struct.new(:chunks, :original_tokens, :processed_tokens, :raw_oversized, :oversized, keyword_init: true)

  class << self
    # 文字種別の式によるトークン数の見積もり（切り上げ）。
    def estimate_tokens(text)
      cost(text).ceil
    end

    # 切り上げ前の見積もり。文字ごとに足し算できるので、塊の合計と連結後で食い違わない。
    def cost(text)
      han = text.scan(/\p{Han}/).size
      non_ascii = text.count("^\u0000-\u007F")
      ascii = text.size - non_ascii
      (han * HAN_WEIGHT + (non_ascii - han) * OTHER_WEIGHT + ascii * ASCII_WEIGHT) * SAFETY
    end

    # 入力の上限（トークン）。num_ctx から、指示文・テンプレート・出力の余裕を引き、100単位で切り捨てる。
    def input_limit
      (((CONTEXT - estimate_tokens(SoraPrompt::INSTRUCTION) - TEMPLATE_RESERVE - OUTPUT_RESERVE) / 100) * 100)
    end

    def call(messages, limit: INPUT_LIMIT, assistant_head_chars: ASSISTANT_HEAD_CHARS)
      new(limit:, assistant_head_chars:).call(messages)
    end
  end

  INPUT_LIMIT = input_limit

  def initialize(limit: INPUT_LIMIT, assistant_head_chars: ASSISTANT_HEAD_CHARS)
    @limit = limit
    @assistant_head_chars = assistant_head_chars
  end

  def call(messages)
    raw = messages.map { |m| render(m.role, m.body.to_s) }
    items = messages.each_with_index.map { |m, i| preprocess(i, m.role, m.body.to_s) }
    Result.new(
      chunks: pack(items),
      original_tokens: raw.sum { |t| self.class.cost(t) }.ceil,
      processed_tokens: items.sum { |it| self.class.cost(render(it.role, it.text)) }.ceil,
      raw_oversized: raw.count { |t| self.class.cost(t) > @limit },
      oversized: items.count { |it| it.marks.include?(:middle) }
    )
  end

  private

  def render(role, text) = "#{LABELS.fetch(role, "【#{role}】")}#{text}"

  def preprocess(index, role, body)
    marks = []
    text = body.dup
    replaced = text.gsub(CODE_BLOCK, OMITTED).sub(UNCLOSED_CODE_BLOCK, OMITTED)
    replaced = replaced.gsub(QUOTE_RUN) { |run| run.size > QUOTE_MAX_CHARS ? "#{OMITTED}\n" : run }
    marks << :omitted if replaced != text
    text = replaced
    if role == "assistant" && text.size > @assistant_head_chars
      text = text[0, @assistant_head_chars] + TRUNCATED_MARK
      marks << :truncated
    end
    if self.class.cost(render(role, text)) > @limit
      text = shorten_middle(role, text)
      marks << :middle
    end
    Item.new(index:, role:, text:, marks:)
  end

  # 先頭と末尾を残して間を MIDDLE_MARK にする。残す文字数を二分探索で決める。
  def shorten_middle(role, text)
    fits = ->(keep) { self.class.cost(render(role, join_middle(text, keep))) <= @limit }
    low = 0
    high = text.size
    while low < high
      mid = (low + high + 1) / 2
      fits.(mid) ? low = mid : high = mid - 1
    end
    join_middle(text, low)
  end

  def join_middle(text, keep)
    head = (keep + 1) / 2
    tail = keep / 2
    "#{text[0, head]}#{MIDDLE_MARK}#{tail.zero? ? "" : text[-tail..]}"
  end

  # 発言の順を保ったまま、上限に収まる範囲で前から詰める。
  def pack(items)
    chunks = []
    current = []
    current_cost = 0.0
    separator_cost = self.class.cost(SEPARATOR)
    items.each do |item|
      item_cost = self.class.cost(render(item.role, item.text))
      added = current.empty? ? item_cost : item_cost + separator_cost
      if !current.empty? && current_cost + added > @limit
        chunks << build_chunk(current)
        current = []
        added = item_cost
        current_cost = 0.0
      end
      current << item
      current_cost += added
    end
    chunks << build_chunk(current) unless current.empty?
    chunks
  end

  def build_chunk(items)
    text = items.map { |it| render(it.role, it.text) }.join(SEPARATOR)
    Chunk.new(items:, text:, tokens: self.class.estimate_tokens(text))
  end
end
