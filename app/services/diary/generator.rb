require "zlib"

module Diary
  # 1つの座について、A（人間の記録）を作って保存するまでの流れ。
  #
  # 1. closed でない座は作らない（open は SegmentRebuilder が作り直す）。
  # 2. InputBuilder で、塊ごとの入力と、座全体のダイジェストを作る。人間の発言がなければ作らない。
  # 3. 同じ（モデル・プロンプトの版・規則の版・入力のダイジェスト）のダイアリーがあれば、飛ばす（冪等）。
  # 4. 塊ごとに Ollama を呼ぶ。同じ（塊・入力・モデル・プロンプトの版）の成功済みの記録があれば再利用する
  #    （中断からの再開と、規則だけを変えたときの LLM なしの再処理）。
  #    JSON の崩れ・長さの打ち切りは、別の seed で1回だけ再試行する。それでも崩れたら、その塊は failed。
  #    通信エラーは、記録せずに例外のまま上げる（ジョブ側で再試行する）。
  # 5. 全塊がそろったら、PostProcessor → DecisionLinker → 引用の検証 → Assembler。
  #    1塊でも failed なら、ダイアリーは作らない（他の座には影響しない）。
  class Generator
    # 最初の1回 + 別の seed での再試行1回。
    MAX_ATTEMPTS = 2

    Result = Struct.new(:status, :segment_id, :entry, :error, keyword_init: true)

    class << self
      attr_writer :client_factory

      def client = (@client_factory || -> { OllamaClient.from_env }).call

      def call(segment, client: nil, detector: nil, limit: SegmentChunker::INPUT_LIMIT) = new(segment, client:, detector:, limit:).call

      # 座とチャンクの添字から、決まった seed を作る（再実行しても同じ。再試行は別の値）。
      def seed_for(segment_id, chunk_index, attempt)
        Zlib.crc32("#{segment_id}:#{chunk_index}:#{attempt}") % 2_147_483_647
      end
    end

    def initialize(segment, client: nil, detector: nil, limit: SegmentChunker::INPUT_LIMIT)
      @segment = segment
      @client = client
      @detector = detector
      @limit = limit
    end

    def call
      return result(:skipped_open) if @segment.end_reason == "open"

      built = InputBuilder.call(@segment, detector: detector, limit: @limit)
      return result(:skipped_no_input) if built.empty?

      existing = DiaryEntry.find_by(segment_id: @segment.id)
      return result(:skipped_up_to_date, entry: existing) if up_to_date?(existing, built)

      notes = []
      built.chunks.each do |chunk|
        chunk_notes, error = notes_for(chunk)
        return result(:failed, error: "塊#{chunk.index}: #{error}") if error

        notes << chunk_notes
      end
      result(:generated, entry: assemble(built, notes))
    end

    private

    def client = @client ||= self.class.client
    def detector = @detector ||= DetectorCache.fetch
    def result(status, entry: nil, error: nil) = Result.new(status:, segment_id: @segment.id, entry:, error:)

    def up_to_date?(entry, built)
      entry && entry.model == client.model && entry.prompt_version == Prompts::A::PROMPT_VERSION &&
        entry.rule_version == Rules::VERSION && entry.input_digest == built.digest
    end

    # 戻り値は [見出しごとの項目, エラーの種類]。
    def notes_for(chunk)
      record = DiaryChunk.find_or_initialize_by(segment_id: @segment.id, chunk_index: chunk.index, input_digest: chunk.digest,
                                                model: client.model, prompt_version: Prompts::A::PROMPT_VERSION)
      if record.persisted? && record.status == "succeeded"
        begin
          return [ NoteParser.call(record.raw_output, chunk_index: chunk.index), nil ]
        rescue NoteParser::ParseError
          nil # 成功済みの記録が読めないときは、作り直す
        end
      end
      generate(record, chunk)
    end

    def generate(record, chunk)
      first_attempt = record.attempts
      MAX_ATTEMPTS.times do |n|
        seed = self.class.seed_for(@segment.id, chunk.index, first_attempt + n)
        response = client.chat(system: Prompts::A::INSTRUCTION, user: chunk.text, schema: Prompts::A::SCHEMA, options: Prompts::A::OPTIONS, seed:)
        record_response(record, response, seed, first_attempt + n + 1)
        notes, kind, message = check(response, chunk)
        if notes
          record.update!(status: "succeeded", error_kind: nil, error_message: nil)
          return [ notes, nil ]
        end
        record.update!(status: "failed", error_kind: kind, error_message: message)
      end
      [ nil, record.error_kind ]
    end

    def record_response(record, response, seed, attempts)
      record.assign_attributes(
        raw_output: response.content, seed:, attempts:, done_reason: response.done_reason, model_digest: client.model_digest,
        prompt_eval_count: response.prompt_eval_count, eval_count: response.eval_count, total_duration_ms: response.total_duration_ms,
        prompt_eval_duration_ms: response.prompt_eval_duration_ms, eval_duration_ms: response.eval_duration_ms
      )
    end

    # [項目, nil, nil]（成功）または [nil, エラーの種類, メッセージ]。
    def check(response, chunk)
      return [ nil, "truncated", "長さの上限で打ち切られました" ] if response.done_reason == "length"

      [ NoteParser.call(response.content, chunk_index: chunk.index), nil, nil ]
    rescue NoteParser::ParseError => e
      [ nil, e.kind.to_s, e.message ]
    end

    def assemble(built, notes)
      outputs = self.class.build_outputs(built, notes)
      Assembler.call(segment: @segment, model: client.model, input_digest: built.digest, items: outputs.items,
                     validation: outputs.validation, links: outputs.links)
    end

    Outputs = Struct.new(:items, :validation, :links, keyword_init: true)

    class << self
      # 塊ごとの項目（NoteParser の結果）から、保存するもの（項目・検証結果・リンク）を作る。LLM は呼ばない。
      # PostProcessor → DecisionLinker → 引用の検証 → 引用の原文化（QuoteRestorer）。
      # 検証とリンクは、モデルの引用で行う（原文化の前後で、正規化した引用は同じ）。保存する引用だけを原文にする。
      def build_outputs(built, notes)
        post = PostProcessor.call(notes)
        linked = DecisionLinker.call(post.items, human_messages: built.human_messages, assistant_messages: built.assistant_messages)
        validation = validation_for(built, post, linked)
        bodies = Message.where(id: built.human_messages.map(&:id)).pluck(:id, :body).to_h
        restore = QuoteRestorer.call(post.items, human_messages: built.human_messages, bodies:)
        validation["quote_restore"] = { "restored" => restore.restored, "unchanged" => restore.unchanged,
                                        "failed" => restore.failed.size, "partial" => restore.partial.size }
        validation["quote_partial"] = restore.partial
        validation["restore_failed"] = restore.failed.transform_values(&:to_s)
        Outputs.new(items: restore.items, validation:, links: linked.links)
      end

      # 引用の検証（塊ごとに、その塊の人間の発言と照合）と、後処理・リンクの件数。本文は入れない。
      def validation_for(built, post, linked)
        counts = Hash.new(0)
        statuses = {}.compare_by_identity
        post.items.values.flatten.group_by(&:chunk_index).each do |index, items|
          result = QuoteVerifier.verify_all(items, own: built.chunks.fetch(index).own_text, other: built.other_text)
          result.counts.each { |key, value| counts[key] += value }
          result.verdicts.each { |item, status| statuses[item] = status }
        end
        item_statuses = post.items.to_h do |heading, items|
          [ heading, items.each_with_index.to_h { |item, i| [ DecisionLinker.item_key(heading, i), statuses[item].to_s ] } ]
        end
        {
          "rule_version" => Rules::VERSION, "prompt_version" => Prompts::A::PROMPT_VERSION, "chunks" => built.chunks.size,
          "counts" => counts, "items" => item_statuses.values.reduce({}, :merge),
          "dropped" => { "count" => post.dropped.size, "by_heading" => post.dropped.map { |item, _| item.heading }.tally },
          "moved" => post.moved.size, "kept_decision_word" => post.kept.size, "unmatched_links" => linked.unmatched
        }
      end
    end
  end
end
