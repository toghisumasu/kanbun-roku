module Diary
  # A の出力への機械後処理（LLM は使わない）。DBには触れない純粋なモジュール。
  # 順序：（0）機微情報の除外（g）→（1）再分類ルール（c）（d）（e）（f）→（2）塊の連結 →（3）見出し間の重複除去。
  #
  # （0）項目の本文または引用で、Rules::SENSITIVE_KEYWORDS の語の前後 Rules::SENSITIVE_WINDOW 字以内に、ASCII の英数字記号の
  #      連続が Rules::SENSITIVE_RUN_MIN 字以上ある項目は、日記から落とす（sensitive に記録する。保存するのは件数だけ）。
  #
  # （1）「決定」の引用が Rules::RECLASSIFY_ENDINGS（ください・お願いします・ますか）で終わる項目は、
  #      依頼とみなして「人間の依頼・共有」へ移す。ただし、引用か本文（NFKC のあと）が決定語（Rules::RECLASSIFY_KEEP_PATTERN）を
  #      含む項目は、決定と依頼の両方を含む可能性があるので、移さず「決定」に残す（kept に記録する）。
  #      （d）引用が STATE_ENDINGS で終わり、決定語を含まない決定 →「人間の依頼・共有」（現状の説明）
  #      （e）引用が REPORT_ENDINGS で終わる REPORT_MAX_CHARS 字以内の短文で、決定語を含まない決定 →「人間の依頼・共有」（事後報告）
  #      （f）引用が「か？」「か。」で終わる決定（決定語を含んでいても）→「未解決」（質問）
  #      （h）引用がお礼・所感の語を含み、決定語も「〜します」も含まない決定 →「人間の考え」
  #      （i）引用が日本語を含まず、コマンドらしい形で始まる決定 →「人間の依頼・共有」（端末の貼り付け）
  #      1つの項目は、c → d → e → f → h → i の順に見て、最初に当たった規則で移る。規則別の移動数は moved_by_rule に数える。
  # （2）複数の塊の座は、全塊の項目を、塊の順・出力の順に連結する。
  # （3）Rules::PRIORITY の順（決定 > 人間の考え > 未解決 > 人間の依頼・共有）に見ていき、本文の文字2-gramの
  #      Dice 係数が Rules::DICE_THRESHOLD 以上の項目が、別の見出しの、優先度の高い側に残っていれば、低い側を落とす。
  #      同じ見出しの中では落とさない。残した項目は、元の順序を保つ。
  module PostProcessor
    RULES = %w[ c d e f h i ].freeze

    Result = Struct.new(:items, :dropped, :moved, :kept, :sensitive, :moved_by_rule, keyword_init: true) do
      # 見出しごとの項目数（後処理後）。
      def counts = items.transform_values(&:size)
    end

    class << self
      # chunks: 塊ごとの { 見出し => [Diary::Item] } の配列（塊の順）。単独の座は要素1つ。
      # items: 見出し => [Item]（Rules::HEADINGS の全見出しを持つ）。
      # dropped: [[落とした項目, 重複相手の項目], ...]。moved: [[移す前の項目, 移した後の項目], ...]。
      # kept: 語尾は再分類の対象だが、決定語を含むため「決定」に残した項目。
      # sensitive: 機微情報の除外（g）で落とした項目（件数の記録用。本文は保存しない）。
      # moved_by_rule: 規則名（c d e f h i）=> 移した数。
      def call(chunks)
        moved = []
        kept = []
        sensitive = []
        by_rule = RULES.to_h { |r| [ r, 0 ] }
        reclassified = chunks.map { |chunk| reclassify(drop_sensitive(chunk, sensitive), moved, kept, by_rule) }
        concatenated = Rules::HEADINGS.to_h { |h| [ h, reclassified.flat_map { |c| c.fetch(h, []) } ] }
        items, dropped = dedupe(concatenated)
        Result.new(items:, dropped:, moved:, kept:, sensitive:, moved_by_rule: by_rule)
      end

      # 機微情報（パスワードなどの語の近くに、英数字記号の連続がある項目）か。
      def sensitive?(item)
        [ item.text, item.quote ].any? { |t| sensitive_text?(t.to_s) }
      end

      # （d）現状の説明：決定の引用が STATE_ENDINGS で終わり、決定語を含まない。
      def state?(item) = item.heading == Rules::RECLASSIFY_FROM && ending?(item, Rules::STATE_ENDINGS) && !decision_word?(item)

      # （e）事後報告：決定の引用が REPORT_ENDINGS で終わる短文で、決定語を含まない。
      def report?(item)
        item.heading == Rules::RECLASSIFY_FROM && ending?(item, Rules::REPORT_ENDINGS) &&
          trimmed_quote(item).size <= Rules::REPORT_MAX_CHARS && !decision_word?(item)
      end

      # （f）質問：決定の引用が「か？」「か。」で終わる（決定語は見ない）。
      def question?(item)
        item.heading == Rules::RECLASSIFY_FROM && item.quote.to_s.unicode_normalize(:nfkc).strip.match?(Rules::QUESTION_ENDING)
      end

      # （h）お礼・所感：決定の引用がお礼・所感の語を含み、決定語も「〜します」も含まない。
      def thanks?(item)
        return false unless item.heading == Rules::RECLASSIFY_FROM

        quote = item.quote.to_s.unicode_normalize(:nfkc)
        Rules::THANKS_WORDS.any? { |word| quote.include?(word) } && !decision_word?(item) && !commit_word?(quote)
      end

      # （i）端末のコマンド：決定の引用が日本語を含まず、コマンドらしい形で始まる。
      def command?(item)
        return false unless item.heading == Rules::RECLASSIFY_FROM

        quote = item.quote.to_s.unicode_normalize(:nfkc).strip
        !quote.empty? && !quote.match?(Rules::JAPANESE_CHARS) && quote.match?(Rules::COMMAND_PATTERN)
      end

      # 項目が移る規則の名前（c d e f h i）。移らなければ nil。
      def move_rule(item)
        return "c" if reclassify?(item)
        return "d" if state?(item)
        return "e" if report?(item)

        return "f" if question?(item)
        return "h" if thanks?(item)

        "i" if command?(item)
      end

      def move_target(rule)
        case rule
        when "f" then Rules::QUESTION_TO
        when "h" then Rules::THANKS_TO
        else Rules::RECLASSIFY_TO
        end
      end

      # 文字2-gram（重複なしの集合）の Dice 係数。どちらかが1文字以下なら 0。
      def dice(a, b)
        x = bigrams(a)
        y = bigrams(b)
        return 0.0 if x.empty? || y.empty?

        2.0 * (x & y).size / (x.size + y.size)
      end

      # 移す項目か。語尾が対象で、かつ決定語を含まない。
      def reclassify?(item) = reclassify_ending?(item) && !decision_word?(item)

      # 「決定」の引用の語尾が、再分類の対象か（決定語は見ない）。
      def reclassify_ending?(item)
        return false unless item.heading == Rules::RECLASSIFY_FROM

        quote = item.quote.to_s.strip.sub(Rules::QUOTE_TRAILING, "")
        Rules::RECLASSIFY_ENDINGS.any? { |ending| quote.end_with?(ending) }
      end

      # 引用か本文（NFKC のあと）が決定語を含むか。
      def decision_word?(item)
        [ item.quote, item.text ].any? { |t| t.to_s.unicode_normalize(:nfkc).match?(Rules::RECLASSIFY_KEEP_PATTERN) }
      end

      private

      def reclassify(chunk, moved, kept, by_rule)
        result = Rules::HEADINGS.to_h { |h| [ h, chunk.fetch(h, []).dup ] }
        kept.concat(result[Rules::RECLASSIFY_FROM].select { |item| reclassify_ending?(item) && decision_word?(item) })
        stay = []
        go = []
        result[Rules::RECLASSIFY_FROM].each do |item|
          rule = move_rule(item)
          rule ? go << [ item, rule ] : stay << item
        end
        result[Rules::RECLASSIFY_FROM] = stay
        go.each do |item, rule|
          after = item.with(heading: move_target(rule))
          moved << [ item, after ]
          by_rule[rule] += 1
          result[after.heading] << after
        end
        result
      end

      # 「〜します」を含むか（「お願いします」「よろしくお願いします」は数えない）。
      def commit_word?(text)
        Rules::COMMIT_EXCLUDED_PHRASES.reduce(text) { |t, phrase| t.gsub(phrase, "") }.include?(Rules::COMMIT_WORD)
      end

      def drop_sensitive(chunk, sensitive)
        chunk.transform_values do |list|
          list.reject { |item| sensitive?(item) && sensitive.push(item) }
        end
      end

      # 引用（NFKC のあと、末尾の記号・空白を除く）。
      def trimmed_quote(item) = item.quote.to_s.unicode_normalize(:nfkc).strip.sub(Rules::QUOTE_TRAILING, "")

      def ending?(item, endings)
        quote = trimmed_quote(item)
        endings.any? { |ending| quote.end_with?(ending) }
      end

      def sensitive_text?(text)
        text.to_enum(:scan, Rules::SENSITIVE_KEYWORDS).map { Regexp.last_match }.any? do |m|
          window = Rules::SENSITIVE_WINDOW
          before = text[[ m.begin(0) - window, 0 ].max...m.begin(0)]
          after = text[m.end(0), window].to_s
          run = /[!-~]{#{Rules::SENSITIVE_RUN_MIN},}/
          [ before, after ].any? { |w| w.match?(run) }
        end
      end

      def dedupe(by_heading)
        kept = Hash.new { |h, k| h[k] = [] }
        dropped = []
        Rules::PRIORITY.each do |heading|
          by_heading.fetch(heading).each do |item|
            text = ClaudePasteDetector.normalize(item.text)
            duplicate = kept.flat_map { |h, entries| h == heading ? [] : entries }.find { |_, other_text| dice(text, other_text) >= Rules::DICE_THRESHOLD }
            if duplicate
              dropped << [ item, duplicate.first ]
            else
              kept[heading] << [ item, text ]
            end
          end
        end
        # 元の順序を保つ（処理は優先度の順だが、保存は見出しごとの元の順）。
        kept_ids = kept.values.flatten(1).map { |item, _| item.object_id }.to_set
        items = by_heading.transform_values { |list| list.select { |item| kept_ids.include?(item.object_id) } }
        [ items, dropped ]
      end

      def bigrams(text)
        (0...[ text.size - 1, 0 ].max).map { |i| text[i, 2] }.uniq
      end
    end
  end
end
