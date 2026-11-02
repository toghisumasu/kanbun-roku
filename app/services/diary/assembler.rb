module Diary
  # 後処理後の A の出力・検証結果・リンクを、DiaryEntry とその diary_links に書く。
  # 1つのトランザクションで、同じ座の既存の行を更新する（行を消さない。注釈を残すため）。リンクは入れ替える。
  # 本文（ログの内容）に当たるのは note の「本文」「引用」だけで、validation には件数と判定だけを入れる。
  module Assembler
    class << self
      # items: PostProcessor の結果の items（見出し => [Item]）。links: DecisionLinker の LinkSpec の配列。
      def call(segment:, model:, input_digest:, items:, validation:, links:, generated_at: Time.current)
        DiaryEntry.transaction do
          entry = DiaryEntry.find_or_initialize_by(segment_id: segment.id)
          entry.assign_attributes(
            entry_date: segment.segment_date, note: note_for(items), validation:, model:,
            prompt_version: Prompts::A::PROMPT_VERSION, rule_version: Rules::VERSION, input_digest:, generated_at:
          )
          entry.save!
          entry.diary_links.delete_all
          links.each do |link|
            entry.diary_links.create!(message_id: link.message_id, item_key: link.item_key, link_kind: link.link_kind)
          end
          entry
        end
      end

      def note_for(items)
        items.transform_values do |list|
          list.map { |item| { "本文" => item.text, "引用" => item.quote, "chunk" => item.chunk_index } }
        end
      end
    end
  end
end
