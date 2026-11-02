module Diary
  # 保存する引用を、人間の発言の原文の該当範囲（部分文字列）に置き換える後処理。DBには触れない純粋なモジュール。
  # モデルの引用は、句読点などの差があっても検証を通る（QuoteVerifier は正規化して比べる）。
  # ここで、正規化後に一致した範囲を、原文の字面に戻す。引用の範囲は変えない（文末まで延ばさない）。
  #
  # - 照合する発言は DecisionLinker と同じ規則（正規化後の引用を含む、時刻が最も早い発言。同時刻は id が小さい方）。
  #   引用とリンク先がずれないようにするため。範囲は、その発言の中の最初の一致。
  # - 範囲の直後に続く句読点・記号は含める（ClaudePasteDetector#match_spans と同じ。空白・改行は含めない）。
  # - 置き換えられないとき（引用が空・どの発言にもない・原文の部分文字列にならない）は、モデルの引用のまま残す。
  # - 文の途中から始まる、または文の途中で終わる引用は、quote_partial として記録する（引用は延ばさない）。
  module QuoteRestorer
    Result = Struct.new(:items, :partial, :failed, :restored, :unchanged, keyword_init: true)

    SENTENCE_END = /[。.!！?？][」』）)]*\z/
    SENTENCE_START = /(?:[。.!！?？\n][」』）)]*|\A)[[:space:]]*\z/

    class << self
      # items_by_heading: 見出し => [Item]。human_messages: 座の人間の発言（DecisionLinker::HumanMessage）。
      # bodies: 発言ID => 原文（Message#body）。あれば、置き換えた範囲が原文の部分文字列かも確かめる。
      # 戻り値の partial は item_key の配列。failed は item_key => 理由（:not_found / :not_in_body）。
      # restored は引用の字面が変わった項目の数、unchanged は変わらなかった（引用がある）項目の数。
      def call(items_by_heading, human_messages:, bodies: {})
        humans = human_messages.map { |m| [ m, ClaudePasteDetector.normalize_with_map(m.text) ] }
        partial = []
        failed = {}
        restored = 0
        unchanged = 0
        items = items_by_heading.to_h do |heading, list|
          [ heading, list.each_with_index.map do |item, index|
            key = DecisionLinker.item_key(heading, index)
            next item if item.quote.to_s.strip.empty?

            span = locate(item.quote, humans, bodies)
            if span.is_a?(Symbol)
              failed[key] = span
              next item
            end
            partial << key if span[:partial]
            span[:quote] == item.quote ? (unchanged += 1; item) : (restored += 1; item.with(quote: span[:quote]))
          end ]
        end
        Result.new(items:, partial:, failed:, restored:, unchanged:)
      end

      private

      def locate(quote, humans, bodies)
        needle = ClaudePasteDetector.normalize(quote)
        return :not_found if needle.empty?

        message, (normalized, map) = humans.select { |_, (text, _)| text.include?(needle) }.min_by { |m, _| [ m.occurred_at, m.id ] }
        return :not_found unless message

        index = normalized.index(needle)
        text = message.text
        from = map[index][0]
        to = map[index + needle.size - 1][1]
        to += 1 while to < text.size && text[to].match?(/[\p{P}\p{S}]/)
        restored = text[from...to]
        return :not_in_body if restored.include?(SegmentChunker::CLAUDE_PASTE_MARK)
        return :not_in_body if bodies.key?(message.id) && !bodies[message.id].include?(restored)

        { quote: restored, partial: partial?(text, from, to) }
      end

      def partial?(text, from, to)
        starts = text[0...from].match?(SENTENCE_START)
        tail = text[to..].to_s
        ends = tail.strip.empty? || tail.match?(/\A[ \t　]*\n/) || text[0...to].match?(SENTENCE_END)
        !(starts && ends)
      end
    end
  end
end
