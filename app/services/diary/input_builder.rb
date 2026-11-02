require "digest"

module Diary
  # 1つの座から、A（人間の記録）の入力を作る。DBを読むのは、このクラスだけ。
  #
  # 入力は「人間の発言」ブロックだけ（utterance と paste_media の印を、日本時間の時刻つきで、時刻順に1発言1行）。
  # Claude の発言と端末出力（paste_text）は入れない。Claude の文の貼り付けは、一致した部分だけを印に置き換える
  # （直前までの assistant 発言とだけ照合）。塊は、人間の発言の分だけで数える（SegmentChunker の flow: false）。
  #
  # 塊ごとに、入力の文（text）とそのダイジェスト、引用の検証で使う人間の発言（own_text）、リンクで使う人間の発言
  # （human_messages。A が見た文と、発言ID・時刻）を持つ。座全体では、逆の発言者の文（other_text。引用が
  # 「逆の発言者のもの」かを見分けるため）、リンクの候補にする assistant メッセージ（会話全体）、座の型を持つ。
  class InputBuilder
    ChunkInput = Struct.new(:index, :text, :digest, :tokens, :human_messages, :own_text, keyword_init: true)
    Built = Struct.new(:segment, :chunks, :other_text, :assistant_messages, :digest, :type, keyword_init: true) do
      def empty? = chunks.empty?
      def human_messages = chunks.flat_map(&:human_messages)
    end

    def self.call(segment, detector:, limit: SegmentChunker::INPUT_LIMIT) = new(segment, detector:, limit:).call

    def self.messages_for(segment)
      Message.where(session_id: segment.session_id, id: segment.first_message_id..segment.last_message_id).order(:id).to_a
    end

    def initialize(segment, detector:, limit: SegmentChunker::INPUT_LIMIT)
      @segment = segment
      @detector = detector
      @limit = limit
    end

    def call
      messages = self.class.messages_for(@segment)
      result = SegmentChunker.call(messages, limit: @limit, human_block: true, flow: false, claude_paste: @detector)
      chunks = result.chunks.each_with_index.map { |chunk, index| chunk_input(chunk, index, messages) }
      Built.new(
        segment: @segment, chunks:,
        other_text: messages.select { |m| m.role == "assistant" }.map { |m| m.body[0, SegmentChunker::ASSISTANT_HEAD_CHARS] }.join("\n"),
        assistant_messages: assistant_messages,
        digest: digest(chunks.map(&:digest).join("|")),
        type: segment_type(messages)
      )
    end

    private

    def chunk_input(chunk, index, messages)
      humans = chunk.items.map do |item|
        message = messages[item.index]
        DecisionLinker::HumanMessage.new(id: message.id, occurred_at: message.occurred_at, text: item.text)
      end
      ChunkInput.new(index:, text: chunk.text, digest: digest(chunk.text), tokens: chunk.tokens,
                     human_messages: humans, own_text: humans.map(&:text).join("\n"))
    end

    def assistant_messages
      Message.where(session_id: @segment.session_id, role: "assistant").order(:id).pluck(:id, :occurred_at)
        .map { |id, at| DecisionLinker::AssistantMessage.new(id:, occurred_at: at) }
    end

    # 貼り付け（paste_text / paste_media）の比率で work / talk。user の発言の分類は、貼り付けの置き換え前の本文で行う。
    def segment_type(messages)
      classes = messages.select { |m| m.role == "user" }.map { |m| MessageClassifier.classify(role: m.role, body: m.body, raw: m.raw) }
      SegmentTyper.call(classes)
    end

    def digest(text) = Digest::SHA256.hexdigest(text)[0, 16]
  end
end
