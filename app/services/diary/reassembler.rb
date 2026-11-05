module Diary
  # 既存のダイアリーを、保存済みの A の出力（diary_chunks の成功した記録）から組み立て直す。LLM は呼ばない。
  # 規則（後処理・引用の検証・引用の原文化）だけを変えたときに使う。同じ DiaryEntry の行を書き換え、リンクを入れ替える（注釈を残す）。
  # 入力のダイジェスト・モデル・プロンプトの版が合う、成功した塊の記録がすべてそろっているときだけ作り直す。
  class Reassembler
    Result = Struct.new(:status, :segment_id, :before, :after, :entry, keyword_init: true)

    # 件数だけ。本文は入れない。
    Stats = Struct.new(:items, :links_source, :links_candidate, :quote_exact, :quote_partial, :restore_failed, :restored, keyword_init: true)

    def self.call(segment, detector:, apply: false, prompt_version: Prompts::A::PROMPT_VERSION) = new(segment, detector:, apply:, prompt_version:).call

    # prompt_version: どの版の塊の記録から組み立てるか（既定は今の版）。旧版を指定すれば、旧版に戻せる。
    def initialize(segment, detector:, apply: false, prompt_version: Prompts::A::PROMPT_VERSION)
      @prompt_version = prompt_version
      @segment = segment
      @detector = detector
      @apply = apply
    end

    def call
      entry = DiaryEntry.find_by(segment_id: @segment.id)
      return result(:skipped_no_entry) unless entry

      built = InputBuilder.call(@segment, detector: @detector)
      return result(:skipped_no_input) if built.empty?

      notes = built.chunks.map { |chunk| VersionOutputs.chunk_notes(@segment, chunk, model: entry.model, prompt_version: @prompt_version) }
      return result(:skipped_no_chunk) if notes.any?(&:nil?)

      outputs = Generator.build_outputs(built, notes, prompt_version: @prompt_version)
      before = stats_before(entry)
      after = stats_after(outputs)
      written = @apply ? write(entry, built, outputs) : nil
      result(@apply ? :reassembled : :dry_run, before:, after:, entry: written)
    end

    private

    def result(status, before: nil, after: nil, entry: nil) = Result.new(status:, segment_id: @segment.id, before:, after:, entry:)

    def write(entry, built, outputs)
      Assembler.call(segment: @segment, model: entry.model, input_digest: built.digest, items: outputs.items,
                     validation: outputs.validation, links: outputs.links, generated_at: entry.generated_at, prompt_version: @prompt_version)
    end

    def stats_before(entry)
      links = entry.diary_links.pluck(:item_key, :message_id, :link_kind)
      quotes = entry.note.flat_map { |heading, list| list.each_with_index.map { |item, i| [ DecisionLinker.item_key(heading, i), item["引用"] ] } }
      stats(quotes, links, partial: nil, failed: nil, restored: nil)
    end

    def stats_after(outputs)
      links = outputs.links.map { |l| [ l.item_key, l.message_id, l.link_kind ] }
      quotes = outputs.items.flat_map { |heading, list| list.each_with_index.map { |item, i| [ DecisionLinker.item_key(heading, i), item.quote ] } }
      restore = outputs.validation["quote_restore"]
      stats(quotes, links, partial: restore["partial"], failed: restore["failed"], restored: restore["restored"])
    end

    def stats(quotes, links, partial:, failed:, restored:)
      bodies = Message.where(id: links.map { |l| l[1] }.uniq).pluck(:id, :body).to_h
      sources = links.select { |l| l[2] == "source" }.group_by(&:first)
      exact = quotes.count do |key, quote|
        quote.present? && sources.fetch(key, []).any? { |l| bodies[l[1]].to_s.include?(quote) }
      end
      Stats.new(items: quotes.size, links_source: links.count { |l| l[2] == "source" },
                links_candidate: links.count { |l| l[2] == "preceding_assistant_candidate" },
                quote_exact: exact, quote_partial: partial, restore_failed: failed, restored:)
    end
  end
end
