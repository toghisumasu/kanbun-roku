module Diary
  # 引用の検証（機械）。DBには触れない純粋なモジュール。
  # 引用と、対応する側の発言を、NFKC・空白・句読点・記号・括弧・アスタリスク・バッククォートを除いて比べる
  # （正規化は ClaudePasteDetector.normalize と同じ）。
  #
  # 判定（Status）:
  #   pass           引用が、対応する側の発言に含まれる
  #   exempt         引用が空で、本文が Rules::EXEMPT_PHRASE を含む（画像・文書だけの発言）。「引用なし」に数えない
  #   no_quote       引用が空
  #   mark_in_quote  引用に「（Claude文の貼り付け）」の印を含む
  #   not_in_input   対応する側の発言にも、逆の発言者の発言にもない
  #   wrong_label    逆の発言者の発言にだけある
  #   short_fragment 正規化後 SHORT_QUOTE_CHARS 字未満で、文の途中から始まり文末で終わる箇所がある
  # 検証でわかるのは、引用が入力にあることまで。本文と引用の意味のずれ（誤読）は検出できない。
  module QuoteVerifier
    STATUSES = %i[ pass exempt no_quote mark_in_quote not_in_input wrong_label short_fragment ].freeze

    Result = Struct.new(:verdicts, :counts, keyword_init: true)

    class << self
      # items: Diary::Item の配列。own: 対応する側の発言（文字列）、other: 逆の発言者の発言（文字列）。
      # 戻り値の verdicts は [[item, status], ...]。counts は total / pass / fail と、状態ごとの件数
      # （total は exempt を除く。fail = total - pass）。
      def verify_all(items, own:, other:)
        texts = Texts.new(own, other)
        verdicts = items.map { |item| [ item, status_for(item, texts) ] }
        Result.new(verdicts:, counts: count(verdicts))
      end

      def verify(item, own:, other:)
        status_for(item, Texts.new(own, other))
      end

      # 正規化後 SHORT_QUOTE_CHARS 字未満の引用が、文の途中から始まり文末で終わる箇所を持つか。
      # 文全体が短い発言（文頭から文末まで）は、断片とはしない。
      def short_fragment?(quote, own)
        return false if normalize(quote).size >= Rules::SHORT_QUOTE_CHARS

        text = light(own)
        needle = light(quote).sub(/[。.!！?？]+\z/, "")
        return false if needle.empty?

        position = 0
        while (index = text.index(needle, position))
          before = index.zero? ? nil : text[index - 1]
          after = text[index + needle.size]
          ends_sentence = after.nil? || after.match?(Rules::SENTENCE_BOUNDARY)
          starts_sentence = before.nil? || before.match?(Rules::SENTENCE_BOUNDARY)
          return true if ends_sentence && !starts_sentence

          position = index + 1
        end
        false
      end

      def normalize(text) = ClaudePasteDetector.normalize(text)

      private

      # 発言の正規化は1回だけにする（項目ごとに長い発言を正規化し直さないため）。
      Texts = Struct.new(:own, :other) do
        def own_normalized = @own_normalized ||= QuoteVerifier.normalize(own)
        def other_normalized = @other_normalized ||= QuoteVerifier.normalize(other)
      end

      def status_for(item, texts)
        quote = item.quote.to_s
        if quote.strip.empty?
          return item.text.to_s.include?(Rules::EXEMPT_PHRASE) ? :exempt : :no_quote
        end

        normalized = normalize(quote)
        return :mark_in_quote if normalized.include?(normalize(SegmentChunker::CLAUDE_PASTE_MARK))
        unless texts.own_normalized.include?(normalized)
          return texts.other_normalized.include?(normalized) ? :wrong_label : :not_in_input
        end
        return :short_fragment if short_fragment?(quote, texts.own)

        :pass
      end

      def light(text) = text.to_s.unicode_normalize(:nfkc).gsub(Rules::LIGHT_STRIP, "")

      def count(verdicts)
        statuses = verdicts.map(&:last)
        counts = STATUSES.to_h { |s| [ s, statuses.count(s) ] }
        total = statuses.size - counts[:exempt]
        counts.merge(total:, fail: total - counts[:pass])
      end
    end
  end
end
