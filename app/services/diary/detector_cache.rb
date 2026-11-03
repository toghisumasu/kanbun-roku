module Diary
  # ClaudePasteDetector は、全会話の assistant 本文から索引を作る（約720万字で、約890MB・約12秒）。
  # プロセスごとに1回だけ作って使い回し、assistant メッセージの件数と最大 id が変わったときだけ作り直す。
  module DetectorCache
    @mutex = Mutex.new

    class << self
      def fetch
        key = %w[ assistant user ].flat_map { |role| [ Message.where(role:).count, Message.where(role:).maximum(:id) ] }
        @mutex.synchronize do
          return @detector if @detector && @key == key

          @detector = nil # 古い索引を先に手放す（2つ並べてメモリを使わないため）
          row = Struct.new(:body, :occurred_at, :session_id)
          rows = ->(role) { Message.where(role:).pluck(:body, :occurred_at, :session_id).map { |b, t, s| row.new(b, t, s) } }
          @detector = ClaudePasteDetector.new(rows.("assistant"), user_messages: rows.("user"))
          @key = key
          @detector
        end
      end

      def reset! = @mutex.synchronize { @detector = nil; @key = nil }
    end
  end
end
