module ClaudeAiExport
  # claude.ai のエクスポートを messages に取り込む。
  # - external_id は発言の uuid、session_id は会話の uuid。
  # - body は content の type=text のブロックだけをつなげたもの。それ以外（thinking / tool_use など）は raw にだけ残す。
  # - (source, external_id) の一意制約で冪等。既にあるものは入れない。
  class Importer
    SOURCE = "claude_ai"
    ROLES = { "human" => "user", "assistant" => "assistant" }.freeze
    # jsonb は NUL（\u0000）を保存できない。raw の中の NUL だけ、この記号に置き換える。
    NUL_SUBSTITUTE = "␀"

    Result = Struct.new(
      :conversations, :empty_conversations, :messages, :to_import, :already_imported,
      :body_empty, :skipped, :raw_nul_replaced, :inserted, keyword_init: true
    )

    def initialize(path, apply: false)
      @path = path
      @apply = apply
    end

    def call
      result = Result.new(conversations: 0, empty_conversations: 0, messages: 0, to_import: 0,
                          already_imported: 0, body_empty: 0, skipped: Hash.new(0), raw_nul_replaced: 0, inserted: 0)
      seen = Set.new

      Message.transaction do
        Reader.new(@path).each_conversation do |conversation|
          result.conversations += 1
          messages = Array(conversation["chat_messages"])
          result.empty_conversations += 1 if messages.empty?

          rows = messages.filter_map { |message| build_row(conversation, message, seen, result) }
          next if rows.empty?

          existing = Message.where(source: SOURCE, external_id: rows.map { |r| r[:external_id] }).pluck(:external_id).to_set
          result.already_imported += existing.size
          fresh = rows.reject { |r| existing.include?(r[:external_id]) }
          result.to_import += fresh.size
          result.body_empty += fresh.count { |r| r[:body].empty? }
          next unless @apply && fresh.any?

          inserted = Message.insert_all(fresh, unique_by: %i[ source external_id ])
          result.inserted += inserted.rows.size
        end
      end
      result
    end

    private
      def build_row(conversation, message, seen, result)
        result.messages += 1
        uuid = message["uuid"].presence
        role = ROLES[message["sender"]]
        occurred_at = parse_time(message["created_at"])
        session_id = conversation["uuid"].presence

        return skip(result, :no_uuid) unless uuid
        return skip(result, :duplicate_uuid_in_file) unless seen.add?(uuid)
        return skip(result, :unknown_sender) unless role
        return skip(result, :no_created_at) unless occurred_at
        return skip(result, :no_conversation_uuid) unless session_id

        raw = sanitize(message)
        result.raw_nul_replaced += 1 if raw != message
        { source: SOURCE, external_id: uuid, session_id: session_id, role: role,
          body: body_of(message), occurred_at: occurred_at, raw: raw }
      end

      def body_of(message)
        blocks = message["content"].is_a?(Array) ? message["content"] : []
        blocks.filter_map { |block| block["text"] if block["type"] == "text" }.join
      end

      def parse_time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end

      def skip(result, reason)
        result.skipped[reason] += 1
        nil
      end

      def sanitize(value)
        case value
        when String then value.include?("\u0000") ? value.gsub("\u0000", NUL_SUBSTITUTE) : value
        when Array then value.map { |v| sanitize(v) }
        when Hash then value.to_h { |k, v| [ sanitize(k), sanitize(v) ] }
        else value
        end
      end
  end
end
