module Diary
  # 決定の取りこぼしの機械的な検査（見落とし検査）。DBには触れない純粋なモジュール。
  # 決定語（または Q:/A: 形式の「A:」の行）を含む人間の発言があるのに、A の「決定」が0の座を見つけるための目印。
  # 見落とし検査そのものは生成の結果に影響しない。ただし DECISION_RE は、再分類（c）で決定に残す判定（Rules::RECLASSIFY_KEEP_PATTERN）
  # にも使うので、変えるときは Rules::VERSION を上げる（指紋に含まれる）。
  module Coverage
    # 決定語。活用形を拾う。「お願いします」「ください」は依頼の言い回しなので入れない。「決定」は広い語で、決定でない使い方も数える。
    DECISION_RE = /に(?:する|します|しました|しましょう)|で(?:いく|いきます|いきましょう)|とします|決めた|決めました|決定|進めます|よしとします|優先します|承認します|採用/
    # 検査用の広い目印。DECISION_RE に、決定の言い回しになりうる語を足したもの。取りこぼしの候補を広く拾うためで、
    # 再分類（c）には使わない（DECISION_RE は変えない）。見落とし検査だけに使うので Rules::VERSION には影響しない。
    BROAD_DECISION_RE = Regexp.union(
      DECISION_RE,
      /にしたい|にしよう|にして(?:ください|くれ|ほしい)?|でお願い|で(?:行く|行き|いこう|いい|よい|OK|ok)|がいい|にしておく|にしておき|それで(?:いく|行く|お願い|進め|やる)|そうします|そうする|やります|やることにし|やめます|やめる|見送り|保留にし|方針|案[A-Z0-9１-９]?で|を選(?:ぶ|び|んだ)|にした|にしました|にしている/
    )
    # 「Q:／A:」形式の「A:」の行（行頭の箇条書き記号は許す）。NFKC のあとで見るので、全角の「Ａ：」も拾う。
    A_LINE = /^\s*[-・*]?\s*A\s*[:：]/

    class << self
      # texts: 人間の発言（A が見た文）の配列。戻り値は、決定語（狭い・広い）を含む発言の数と、「A:」の行を含む発言の数。
      def count(texts)
        normalized = texts.map { |t| t.to_s.unicode_normalize(:nfkc) }
        { decision_words: normalized.count { |t| t.match?(DECISION_RE) },
          broad_decision_words: normalized.count { |t| t.match?(BROAD_DECISION_RE) },
          a_lines: normalized.count { |t| t.match?(A_LINE) } }
      end
    end
  end
end
