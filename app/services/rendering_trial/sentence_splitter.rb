module RenderingTrial
  # 項目の本文を文に分ける。区切りは「。」「！」「？」（続く区切りは1つにまとめる）と改行。
  # 区切りの記号は文の末尾に残す。記号と空白だけの文は捨てる。
  module SentenceSplitter
    SPLIT = /(?<=[。！？])(?![。！？])|\r?\n/
    EMPTY = /[。！？[:space:]]/

    def self.call(text)
      text.to_s.split(SPLIT).map(&:strip).reject { |sentence| sentence.gsub(EMPTY, "").empty? }
    end
  end
end
