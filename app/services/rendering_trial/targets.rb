module RenderingTrial
  # 試作の対象にする日記の項目。現行採用分（プロンプトの版・規則の版が今のもの）の diary_entries から、
  # 指定した日付（座の開始日。entry_date）の「決定」「人間の考え」の項目を取る。入力は項目の本文（note の「本文」）だけ。
  # 本文が空の項目は除く。DBは読むだけ。
  module Targets
    HEADINGS = %w[ 決定 人間の考え ].freeze

    Item = Struct.new(:date, :segment_id, :item_key, :body, keyword_init: true)
    Selection = Struct.new(:items, :skipped_empty, keyword_init: true)

    def self.call(dates, prompt_version: Diary::Prompts::A::PROMPT_VERSION, rule_version: Diary::Rules::VERSION)
      items = []
      skipped = 0
      DiaryEntry.where(entry_date: dates, prompt_version:, rule_version:).order(:entry_date, :segment_id).each do |entry|
        HEADINGS.each do |heading|
          Array(entry.note[heading]).each_with_index do |raw, index|
            body = raw["本文"].to_s.strip
            if body.empty?
              skipped += 1
            else
              items << Item.new(date: entry.entry_date.to_s, segment_id: entry.segment_id, item_key: Diary::DecisionLinker.item_key(heading, index), body:)
            end
          end
        end
      end
      Selection.new(items:, skipped_empty: skipped)
    end
  end
end
