# 1つの区切りの発言列を、曽良モードの入力（塊）に整える。DBには触れない純粋な関数。
# 入力は role / body に答える発言の列（区切りの順）。出力は塊の列で、発言の境界で分ける。
#
# 前処理:
# - 貼り付け（MessageClassifier が paste_text とみなした user の発言）は、先頭 PASTE_HEAD_LINES 行と
#   末尾 PASTE_TAIL_LINES 行だけ残し、間を「（貼付のため N 行省略）」にする。trim_paste: false で止められる。
# - claude_paste: に ClaudePasteDetector を渡すと、Claude の文の貼り付けと判定した utterance は、一致した部分だけを
#   「（Claude文の貼り付け）」に置き換える（一致が発言全体に占める割合は問わない）。session_id のある発言には、短い貼り付けの行規則も働く
#   （ClaudePasteDetector の説明を見ること）。照合の対象は、その発言より前の時刻の
#   assistant メッセージだけ（発言に occurred_at がなければ制限しない）。一致しない部分はそのまま残し、
#   以降の前処理に進む（body には書き込まない）。残りにシェルのプロンプト行などがあれば paste_text として扱う。
# - human_block: true のときは、塊の先頭に「人間の発言」ブロックを置き、続けて「流れ」を置く。
#   ブロックには role=user のうち utterance と paste_media（の印）だけを、日本時間の時刻つきで全件並べる。
#   paste_text（端末出力）は入れない。「流れ」は今までどおり（時刻順、user は全文・貼付は先頭と末尾の数行、
#   assistant は先頭 ASSISTANT_HEAD_CHARS 文字）。塊ごとに、その塊の発言だけでブロックを作る。
# - flow: false のときは、塊の中身は「人間の発言」ブロックだけ（見出しなし、1発言1行）で、「流れ」は作らない。
#   A（人間の記録）の入力用。塊の分け方も、人間の発言の分だけで数える（assistant や端末出力の分は数えない）。
#   human_block: true が前提。上限（limit）は、ブロックだけの入力に対して効く。
# - 本文が空の user の発言には、入力でだけ使う印を入れる。raw に image があれば「（画像）」、document があれば
#   「（文書）」（両方なら続けて）、手がかりがなければ「（添付・本文なし）」。body には書き込まない。
# - コードブロックと長い引用は「（省略）」に置き換える（user・assistant とも）。
# - user は全文、assistant は先頭 ASSISTANT_HEAD_CHARS 文字だけ残し、切った箇所に「…（以下略）」を付ける。
# - 前処理後も単独で INPUT_LIMIT を超える発言は、先頭と末尾を残し、間を「（中略）」にする。
#
# トークン数は文字種別の式で見積もる。重みは claude.ai エクスポートの実データ30区間
# （Ollama qwen3-14b の prompt_eval_count）で較正した。根拠は下の定数のコメントを見ること。
# 実データでの塊数・削減率は `bin/rails segments:chunk_report`（読み取りのみ）で確かめる。
class SegmentChunker
  CONTEXT = 16_384
  # 出力（思考なし）の余裕。A の num_predict（Diary::Prompts::A::OPTIONS）と同じ値にする。
  # 入力 + 指示文 + テンプレート + num_predict が num_ctx に収まれば、出力が上限まで伸びても、入力は切り詰められない。
  # 同じ値であることは、test/services/segment_chunker_test.rb が確かめる。
  OUTPUT_RESERVE = 3_000
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
  PASTE_HEAD_LINES = 5
  PASTE_TAIL_LINES = 5
  # 連続する引用行（> で始まる行）の合計がこの文字数を超えたら省略する。
  QUOTE_MAX_CHARS = 300

  MEDIA_MARKS = { image: "（画像）", document: "（文書）" }.freeze
  EMPTY_MARK = "（添付・本文なし）".freeze
  CLAUDE_PASTE_MARK = "（Claude文の貼り付け）".freeze
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
  # human: 「人間の発言」ブロックに載せる発言か。at: 発言時刻（なければ nil）。
  Item = Struct.new(:index, :role, :text, :marks, :human, :at, keyword_init: true)
  HUMAN_HEADER = "【人間の発言】\n".freeze
  FLOW_HEADER = "【流れ】\n".freeze
  NO_HUMAN = "（なし）".freeze
  Result = Struct.new(:chunks, :original_tokens, :processed_tokens, :raw_oversized, :oversized, keyword_init: true)
  EMPTY_RAW = {}.freeze

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
    # INPUT_LIMIT はこの計算の結果を書き写した定数（A の指示文は Diary::Prompts::A::INSTRUCTION）。
    # 指示文を変えたら、test/services/segment_chunker_test.rb が、定数と計算結果のずれを検出する。
    def input_limit(instruction)
      (((CONTEXT - estimate_tokens(instruction) - TEMPLATE_RESERVE - OUTPUT_RESERVE) / 100) * 100)
    end

    def call(messages, limit: INPUT_LIMIT, assistant_head_chars: ASSISTANT_HEAD_CHARS, trim_paste: true, human_block: false, claude_paste: nil, flow: true)
      new(limit:, assistant_head_chars:, trim_paste:, human_block:, claude_paste:, flow:).call(messages)
    end

    # 貼り付けの先頭と末尾の数行だけを残す。行数が足りなければそのまま返す。
    def trim_paste_lines(body, head: PASTE_HEAD_LINES, tail: PASTE_TAIL_LINES)
      lines = body.lines
      return body if lines.size <= head + tail + 1

      omitted = lines.size - head - tail
      head_part = lines.first(head).join
      head_part += "\n" unless head_part.end_with?("\n")
      "#{head_part}（貼付のため#{omitted}行省略）\n#{lines.last(tail).join}"
    end
  end

  # A の実際の指示文（1,266トークンの見積もり）と num_predict（3,000）で計算した値：16,384 − 1,266 − 100 − 3,000 = 12,018 → 12,000。
  # （旧版 A-2026-11-02.1 は 839 トークンで 12,400 だった。全825座で、12,400 と 12,000 の塊の分け方・入力のダイジェストは同じ。）
  INPUT_LIMIT = 12_000

  def initialize(limit: INPUT_LIMIT, assistant_head_chars: ASSISTANT_HEAD_CHARS, trim_paste: true, human_block: false, claude_paste: nil, flow: true)
    raise ArgumentError, "flow: false には human_block: true が要ります" if !flow && !human_block

    @flow = flow
    @limit = limit
    @claude_paste = claude_paste
    @assistant_head_chars = assistant_head_chars
    @trim_paste = trim_paste
    @human_block = human_block
  end

  def call(messages)
    raw = messages.map { |m| render(m.role, m.body.to_s) }
    items = messages.each_with_index.map { |m, i| preprocess(i, m.role, m.body.to_s, raw_of(m), at_of(m), session_of(m)) }
    @time_format = time_format(items)
    Result.new(
      chunks: pack(items),
      original_tokens: raw.sum { |t| self.class.cost(t) }.ceil,
      processed_tokens: items.sum { |it| item_cost(it) }.ceil,
      raw_oversized: raw.count { |t| self.class.cost(t) > @limit },
      oversized: items.count { |it| it.marks.include?(:middle) }
    )
  end

  private

  def render(role, text) = "#{LABELS.fetch(role, "【#{role}】")}#{text}"

  # raw は任意（なければ貼り付けの判定は本文だけで行う）。
  def raw_of(message) = message.respond_to?(:raw) ? message.raw : EMPTY_RAW

  def at_of(message) = message.respond_to?(:occurred_at) ? message.occurred_at : nil

  def session_of(message) = message.respond_to?(:session_id) ? message.session_id : nil

  def preprocess(index, role, body, raw, at, session = nil)
    kind = MessageClassifier.classify(role:, body:, raw:)
    if role == "user" && body.strip.empty?
      return Item.new(index:, role:, text: empty_user_mark(raw), marks: [ :media ], human: true, at:)
    end

    marks = []
    text = body.dup
    if @claude_paste && kind == :utterance && role == "user" && @claude_paste.paste?(body, before: at, session:)
      text = @claude_paste.mask(body, CLAUDE_PASTE_MARK, before: at, session:)
      marks << :claude_paste
      if MessageClassifier.prompt_lines?(text)
        kind = :paste_text
        marks << :moved_to_paste_text
      end
    end
    human = role == "user" && kind != :paste_text
    if @trim_paste && kind == :paste_text
      trimmed = self.class.trim_paste_lines(text)
      if trimmed != text
        marks << :pasted
        text = trimmed
      end
    end
    replaced = text.gsub(CODE_BLOCK, OMITTED).sub(UNCLOSED_CODE_BLOCK, OMITTED)
    replaced = replaced.gsub(QUOTE_RUN) { |run| run.size > QUOTE_MAX_CHARS ? "#{OMITTED}\n" : run }
    marks << :omitted if replaced != text
    text = replaced
    if role == "assistant" && text.size > @assistant_head_chars
      text = text[0, @assistant_head_chars] + TRUNCATED_MARK
      marks << :truncated
    end
    cap = item_limit(human)
    if self.class.cost(render(role, text)) > cap
      text = shorten_middle(role, text, cap)
      marks << :middle
    end
    Item.new(index:, role:, text:, marks:, human:, at:)
  end

  # 「人間の発言」ブロックにも載る発言は、同じ文が2回入るので、1回あたりの上限を半分にする。
  # 流れを作らない（flow: false）ときは、人間の発言は1回しか入らないので、半分にしない。
  def item_limit(human)
    return @limit unless @human_block

    available = @limit - fixed_cost
    human && @flow ? available / 2 : available
  end

  def fixed_cost
    @fixed_cost ||= self.class.cost(@flow ? HUMAN_HEADER + FLOW_HEADER + NO_HUMAN + SEPARATOR : NO_HUMAN)
  end

  # 発言が2日以上にまたがるときだけ、時刻に月日を付ける。
  def time_format(items)
    dates = items.filter_map { |it| it.at&.in_time_zone(ConversationSegmenter::JST)&.to_date }.uniq
    dates.size > 1 ? "%m/%d %H:%M" : "%H:%M"
  end

  def human_line(item)
    stamp = item.at ? "[#{item.at.in_time_zone(ConversationSegmenter::JST).strftime(@time_format)}] " : ""
    "#{stamp}#{item.text}"
  end

  def item_cost(item)
    unless @flow
      return item.human ? self.class.cost(human_line(item) + "\n") : 0.0
    end

    cost = self.class.cost(render(item.role, item.text))
    cost += self.class.cost(human_line(item) + "\n") if @human_block && item.human
    cost
  end

  def empty_user_mark(raw)
    kinds = MessageClassifier.media_kinds(raw)
    kinds.empty? ? EMPTY_MARK : kinds.map { |k| MEDIA_MARKS.fetch(k) }.join
  end

  # 先頭と末尾を残して間を MIDDLE_MARK にする。残す文字数を二分探索で決める。
  def shorten_middle(role, text, cap)
    fits = ->(keep) { self.class.cost(render(role, join_middle(text, keep))) <= cap }
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
    base = @human_block ? fixed_cost : 0.0
    current_cost = base
    separator_cost = self.class.cost(SEPARATOR)
    items.each do |item|
      next unless @flow || item.human

      cost = item_cost(item)
      added = current.empty? || !@flow ? cost : cost + separator_cost
      if !current.empty? && current_cost + added > @limit
        chunks << build_chunk(current)
        current = []
        added = cost
        current_cost = base
      end
      current << item
      current_cost += added
    end
    chunks << build_chunk(current) unless current.empty?
    chunks
  end

  def build_chunk(items)
    unless @flow
      lines = items.map { |it| human_line(it) }
      text = lines.join("\n")
      return Chunk.new(items:, text:, tokens: self.class.estimate_tokens(text))
    end

    text = items.map { |it| render(it.role, it.text) }.join(SEPARATOR)
    if @human_block
      lines = items.select(&:human).map { |it| human_line(it) }
      text = "#{HUMAN_HEADER}#{lines.empty? ? NO_HUMAN : lines.join("\n")}#{SEPARATOR}#{FLOW_HEADER}#{text}"
    end
    Chunk.new(items:, text:, tokens: self.class.estimate_tokens(text))
  end
end
