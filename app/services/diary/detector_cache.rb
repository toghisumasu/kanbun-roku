module Diary
  # ClaudePasteDetector は、全会話の assistant 本文から索引を作る（約720万字で、約890MB・約12秒）。
  # プロセスごとに1回だけ作って使い回し、assistant メッセージの件数と最大 id が変わったときだけ作り直す。
  module DetectorCache
    @mutex = Mutex.new

    class << self
      def fetch
        key = [ Message.where(role: "assistant").count, Message.where(role: "assistant").maximum(:id) ]
        @mutex.synchronize do
          return @detector if @detector && @key == key

          @detector = nil # 古い索引を先に手放す（2つ並べてメモリを使わないため）
          assistant = Struct.new(:body, :occurred_at)
          @detector = ClaudePasteDetector.new(Message.where(role: "assistant").pluck(:body, :occurred_at).map { |b, t| assistant.new(b, t) })
          @key = key
          @detector
        end
      end

      def reset! = @mutex.synchronize { @detector = nil; @key = nil }
    end
  end
end
