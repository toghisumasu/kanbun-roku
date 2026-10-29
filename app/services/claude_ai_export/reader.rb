module ClaudeAiExport
  # conversations.json（トップレベルが会話の配列）から、会話を1件ずつ取り出す。
  # ファイル全体を JSON.parse するとメモリを食うので、トップレベルの要素の境目だけを
  # バイト単位で探し、1件ずつ parse する。
  class Reader
    CHUNK_SIZE = 4.megabytes
    QUOTE, BACKSLASH = 0x22, 0x5c
    OPEN_BRACE, OPEN_BRACKET, CLOSE_BRACE, CLOSE_BRACKET = 0x7b, 0x5b, 0x7d, 0x5d

    def initialize(path, chunk_size: CHUNK_SIZE)
      @path = path
      @chunk_size = chunk_size
    end

    def each_conversation
      return enum_for(:each_conversation) unless block_given?

      depth = 0
      in_string = escaped = false
      pending = nil # チャンクをまたぐ要素の、ここまでのバイト列
      start = nil   # 現在のチャンク内での要素の開始位置

      File.open(@path, "rb") do |file|
        while (chunk = file.read(@chunk_size))
          start = 0 if pending
          chunk.each_byte.with_index do |byte, i|
            if in_string
              if escaped then escaped = false
              elsif byte == BACKSLASH then escaped = true
              elsif byte == QUOTE then in_string = false
              end
              next
            end

            case byte
            when QUOTE then in_string = true
            when OPEN_BRACE, OPEN_BRACKET
              depth += 1
              start = i if depth == 2
            when CLOSE_BRACE, CLOSE_BRACKET
              depth -= 1
              if depth == 1 && start
                json = pending ? pending + chunk.byteslice(start..i) : chunk.byteslice(start..i)
                pending = start = nil
                yield JSON.parse(json.force_encoding(Encoding::UTF_8))
              end
            end
          end
          pending = (pending || "".b) + chunk.byteslice(start..) if start
          start = nil
        end
      end
    end
  end
end
