module Diary
  # 決定の取りこぼしの機械的な検査（見落とし検査）。DBには触れない純粋なモジュール。
  # 決定語（または Q:/A: 形式の「A:」の行）を含む人間の発言があるのに、A の「決定」が0の座を見つけるための目印。
  # 生成の結果には影響しない（規則の版 Rules::VERSION には含めない）。
  module Coverage
    # 決定語。活用形を拾う。「お願いします」「ください」は依頼の言い回しなので入れない。「決定」は広い語で、決定でない使い方も数える。
    DECISION_RE = /に(?:する|します|しました|しましょう)|で(?:いく|いきます|いきましょう)|とします|決めた|決めました|決定|進めます|よしとします|優先します|承認します|採用/
    # 「Q:／A:」形式の「A:」の行（行頭の箇条書き記号は許す）。NFKC のあとで見るので、全角の「Ａ：」も拾う。
    A_LINE = /^\s*[-・*]?\s*A\s*[:：]/

    class << self
      # texts: 人間の発言（A が見た文）の配列。戻り値は、決定語を含む発言の数と、「A:」の行を含む発言の数。
      def count(texts)
        normalized = texts.map { |t| t.to_s.unicode_normalize(:nfkc) }
        { decision_words: normalized.count { |t| t.match?(DECISION_RE) }, a_lines: normalized.count { |t| t.match?(A_LINE) } }
      end
    end
  end
end
