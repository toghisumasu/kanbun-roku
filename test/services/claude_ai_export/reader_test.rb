require "test_helper"

class ClaudeAiExport::ReaderTest < ActiveSupport::TestCase
  test "yields each conversation, whatever the chunk size" do
    conversations = [
      { "uuid" => "c-1", "name" => "括弧 {[ と引用符 \" と \\ を含む", "chat_messages" => [ { "text" => "日本語 \u{1F600}" } ] },
      { "uuid" => "c-2", "chat_messages" => [] },
      { "uuid" => "c-3", "chat_messages" => [ { "text" => "}]\\\\\"" } ] }
    ]
    with_json_file(conversations.to_json) do |path|
      [ 1, 2, 7, 64, 4096 ].each do |chunk_size|
        assert_equal conversations, ClaudeAiExport::Reader.new(path, chunk_size: chunk_size).each_conversation.to_a,
                     "chunk_size=#{chunk_size}"
      end
    end
  end

  test "empty array yields nothing" do
    with_json_file("[]") { |path| assert_empty ClaudeAiExport::Reader.new(path).each_conversation.to_a }
  end

  private
    def with_json_file(json)
      Tempfile.create([ "conversations", ".json" ]) do |file|
        file.write(json)
        file.flush
        yield file.path
      end
    end
end
