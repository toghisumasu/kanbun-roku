require "test_helper"

# ダミーデータだけを使う。実データの抜粋は書かないこと（このリポジトリは公開）。
class ClaudeAiExport::ImporterTest < ActiveSupport::TestCase
  test "dry-run counts but does not write" do
    result = import(apply: false)

    assert_equal 0, Message.count
    assert_equal 2, result.conversations
    assert_equal 1, result.empty_conversations
    assert_equal 5, result.messages
    assert_equal 3, result.to_import
    assert_equal 1, result.body_empty
    assert_equal({ unknown_sender: 1, duplicate_uuid_in_file: 1 }, result.skipped)
  end

  test "apply imports text blocks only and keeps the whole message in raw" do
    result = import(apply: true)
    assert_equal 3, result.inserted

    human = Message.find_by!(source: "claude_ai", external_id: "m-1")
    assert_equal "user", human.role
    assert_equal "c-1", human.session_id
    assert_equal Time.utc(2026, 5, 23, 2, 6, 33, 680931), human.occurred_at
    assert_equal "こんにちは", human.body
    assert_equal "human", human.raw["sender"]

    assistant = Message.find_by!(external_id: "m-2")
    assert_equal "assistant", assistant.role
    assert_equal "前半後半", assistant.body
    assert_equal %w[ thinking text tool_use tool_result text ], assistant.raw["content"].map { |b| b["type"] }
    assert_equal "秘密の思考", assistant.raw["content"].first["thinking"]

    empty = Message.find_by!(external_id: "m-3")
    assert_equal "", empty.body
  end

  test "importing twice does not duplicate" do
    import(apply: true)
    result = import(apply: true)

    assert_equal 3, Message.count
    assert_equal 0, result.inserted
    assert_equal 3, result.already_imported
  end

  test "NUL in raw is replaced because jsonb cannot store it" do
    result = import(apply: true)

    assert_equal 1, result.raw_nul_replaced
    assert_equal "a␀b", Message.find_by!(external_id: "m-3").raw["content"].first["content"]
  end

  private
    def conversations
      [
        { "uuid" => "c-1", "chat_messages" => [
          { "uuid" => "m-1", "sender" => "human", "created_at" => "2026-05-23T02:06:33.680931Z",
            "text" => "こんにちは", "content" => [ { "type" => "text", "text" => "こんにちは" } ] },
          { "uuid" => "m-2", "sender" => "assistant", "created_at" => "2026-05-23T02:06:40.000000Z",
            "text" => "前半後半", "content" => [
              { "type" => "thinking", "thinking" => "秘密の思考" },
              { "type" => "text", "text" => "前半" },
              { "type" => "tool_use", "id" => "t-1", "name" => "x" },
              { "type" => "tool_result", "tool_use_id" => "t-1", "content" => [] },
              { "type" => "text", "text" => "後半" }
            ] },
          { "uuid" => "m-3", "sender" => "assistant", "created_at" => "2026-05-23T02:07:00.000000Z",
            "text" => "", "content" => [ { "type" => "tool_result", "tool_use_id" => "t-2", "content" => "a\u0000b" } ] },
          { "uuid" => "m-4", "sender" => "system", "created_at" => "2026-05-23T02:08:00.000000Z", "content" => [] },
          { "uuid" => "m-1", "sender" => "human", "created_at" => "2026-05-23T02:09:00.000000Z", "content" => [] }
        ] },
        { "uuid" => "c-2", "chat_messages" => [] }
      ]
    end

    def import(apply:)
      Tempfile.create([ "conversations", ".json" ]) do |file|
        file.write(conversations.to_json)
        file.flush
        ClaudeAiExport::Importer.new(file.path, apply: apply).call
      end
    end
end
