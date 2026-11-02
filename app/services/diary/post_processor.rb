module Diary
  # A の出力への機械後処理（LLM は使わない）。DBには触れない純粋なモジュール。
  # 順序：（1）再分類ルール（c）→（2）塊の連結 →（3）見出し間の重複除去。
  #
  # （1）「決定」の引用が Rules::RECLASSIFY_ENDINGS（ください・お願いします・ますか）で終わる項目は、
  #      依頼とみなして「人間の依頼・共有」へ移す。
  # （2）複数の塊の座は、全塊の項目を、塊の順・出力の順に連結する。
  # （3）Rules::PRIORITY の順（決定 > 人間の考え > 未解決 > 人間の依頼・共有）に見ていき、本文の文字2-gramの
  #      Dice 係数が Rules::DICE_THRESHOLD 以上の項目が、別の見出しの、優先度の高い側に残っていれば、低い側を落とす。
  #      同じ見出しの中では落とさない。残した項目は、元の順序を保つ。
  module PostProcessor
    Result = Struct.new(:items, :dropped, :moved, keyword_init: true) do
      # 見出しごとの項目数（後処理後）。
      def counts = items.transform_values(&:size)
    end

    class << self
      # chunks: 塊ごとの { 見出し => [Diary::Item] } の配列（塊の順）。単独の座は要素1つ。
      # items: 見出し => [Item]（Rules::HEADINGS の全見出しを持つ）。
      # dropped: [[落とした項目, 重複相手の項目], ...]。moved: [[移す前の項目, 移した後の項目], ...]。
      def call(chunks)
        moved = []
        reclassified = chunks.map { |chunk| reclassify(chunk, moved) }
        concatenated = Rules::HEADINGS.to_h { |h| [ h, reclassified.flat_map { |c| c.fetch(h, []) } ] }
        items, dropped = dedupe(concatenated)
        Result.new(items:, dropped:, moved:)
      end

      # 文字2-gram（重複なしの集合）の Dice 係数。どちらかが1文字以下なら 0。
      def dice(a, b)
        x = bigrams(a)
        y = bigrams(b)
        return 0.0 if x.empty? || y.empty?

        2.0 * (x & y).size / (x.size + y.size)
      end

      def reclassify?(item)
        return false unless item.heading == Rules::RECLASSIFY_FROM

        quote = item.quote.to_s.strip.sub(Rules::QUOTE_TRAILING, "")
        Rules::RECLASSIFY_ENDINGS.any? { |ending| quote.end_with?(ending) }
      end

      private

      def reclassify(chunk, moved)
        result = Rules::HEADINGS.to_h { |h| [ h, chunk.fetch(h, []).dup ] }
        stay, go = result[Rules::RECLASSIFY_FROM].partition { |item| !reclassify?(item) }
        result[Rules::RECLASSIFY_FROM] = stay
        go.each do |item|
          after = item.with(heading: Rules::RECLASSIFY_TO)
          moved << [ item, after ]
          result[Rules::RECLASSIFY_TO] << after
        end
        result
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
