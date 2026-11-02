module Diary
  # 項目から原本の発言へのリンクを、機械的に決める（LLM は使わない）。DBには触れない純粋なモジュール。
  #
  # - source リンク：項目の引用を、座の中の人間の発言（A が見た文）と正規化して照合し、含む発言に結ぶ。
  #   複数の発言に一致するときは、座の中で時刻（occurred_at）が最も早いもの。同時刻なら id が小さい方。
  #   決定的に1つに決めるための規則で、正しい発言とは限らない。一致しないときは、リンクを付けない。
  # - 候補リンク（preceding_assistant_candidate）：Rules::CANDIDATE_HEADINGS（決定）の項目だけ。
  #   source の発言より前の時刻で、最も後ろの assistant メッセージを結ぶ。直前の発言が、決定の対象とした提案とは
  #   限らないので、候補として記録し（link_kind で区別）、断定しない。
  # - item_key は「見出し:通し番号」（後処理後の、見出しごとの0始まりの位置）。例「決定:2」。
  module DecisionLinker
    # text は、A の入力に載った文（貼り付けの置き換え後）。
    HumanMessage = Struct.new(:id, :occurred_at, :text, keyword_init: true)
    AssistantMessage = Struct.new(:id, :occurred_at, keyword_init: true)
    LinkSpec = Data.define(:item_key, :message_id, :link_kind)
    Result = Struct.new(:links, :unmatched, keyword_init: true)

    class << self
      def item_key(heading, index) = "#{heading}#{Rules::ITEM_KEY_SEPARATOR}#{index}"

      # items_by_heading: PostProcessor の結果の items（見出し => [Diary::Item]）。
      # human_messages: 座の人間の発言（HumanMessage）。assistant_messages: 候補にする assistant メッセージ
      # （座の前の発言も含めてよい。同じ会話のもの）。
      # unmatched: 引用はあるが、一致する人間の発言がなかった項目の item_key。
      def call(items_by_heading, human_messages:, assistant_messages:)
        humans = human_messages.map { |m| [ m, ClaudePasteDetector.normalize(m.text) ] }
        links = []
        unmatched = []
        items_by_heading.each do |heading, items|
          items.each_with_index do |item, index|
            quote = ClaudePasteDetector.normalize(item.quote)
            next if quote.empty?

            key = item_key(heading, index)
            source = earliest(humans, quote)
            if source.nil?
              unmatched << key
              next
            end
            links << LinkSpec.new(item_key: key, message_id: source.id, link_kind: "source")
            next unless Rules::CANDIDATE_HEADINGS.include?(heading)

            candidate = preceding(assistant_messages, source.occurred_at)
            links << LinkSpec.new(item_key: key, message_id: candidate.id, link_kind: "preceding_assistant_candidate") if candidate
          end
        end
        Result.new(links:, unmatched:)
      end

      private

      def earliest(humans, normalized_quote)
        humans.select { |_, text| text.include?(normalized_quote) }.map(&:first).min_by { |m| [ m.occurred_at, m.id ] }
      end

      def preceding(assistants, time)
        assistants.select { |m| m.occurred_at < time }.max_by { |m| [ m.occurred_at, m.id ] }
      end
    end
  end
end
