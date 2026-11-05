module Diary
  # 保存済みの塊の記録（diary_chunks の成功したもの）から、指定した版の A の結果を組み立てる。
  # LLM は呼ばず、DBにも書かない（読み取りのみ）。旧版と新版を並べて比べるとき（diary:compare / diary:show VERSION=）と、
  # 既存のダイアリーの組み立て直し（Reassembler）が使う。
  module VersionOutputs
    # built: InputBuilder の結果。notes: 塊ごとの NoteParser の結果（後処理の前）。
    # post: PostProcessor の結果（再分類(c)・連結・重複除去のあと）。outputs: Generator.build_outputs の結果。
    Result = Struct.new(:built, :notes, :post, :outputs, keyword_init: true)

    class << self
      # 塊の記録がそろっていなければ nil（入力がない座も nil）。
      def call(segment, detector:, model:, prompt_version:)
        built = InputBuilder.call(segment, detector:)
        return nil if built.empty?

        notes = built.chunks.map { |chunk| chunk_notes(segment, chunk, model:, prompt_version:) }
        return nil if notes.any?(&:nil?)

        Result.new(built:, notes:, post: PostProcessor.call(notes), outputs: Generator.build_outputs(built, notes, prompt_version:))
      end

      # 成功した塊の記録がなければ nil。
      def chunk_notes(segment, chunk, model:, prompt_version:)
        record = DiaryChunk.find_by(segment_id: segment.id, chunk_index: chunk.index, input_digest: chunk.digest, model:,
                                    prompt_version:, status: "succeeded")
        record && NoteParser.call(record.raw_output, chunk_index: chunk.index)
      rescue NoteParser::ParseError
        nil
      end
    end
  end
end
