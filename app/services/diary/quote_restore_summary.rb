module Diary
  # diary:report の「引用の原文化」の行。validation["quote_restore"] を座をまたいで合計する。DBには触れない（表示だけ）。
  # validation["quote_restore"] を持たない座（原文化の導入前に作ったもの）は、0として数える。
  module QuoteRestoreSummary
    Summary = Struct.new(:restored, :restored_segments, :unchanged, :failed, :partial, keyword_init: true)

    class << self
      # entries: validation（Hash）を持つもの（DiaryEntry）の配列。
      def call(entries)
        counts = entries.map { |e| (e.validation || {}).fetch("quote_restore", {}) }
        Summary.new(
          restored: counts.sum { |c| c["restored"].to_i },
          restored_segments: counts.count { |c| c["restored"].to_i.positive? },
          unchanged: counts.sum { |c| c["unchanged"].to_i },
          failed: counts.sum { |c| c["failed"].to_i },
          partial: counts.sum { |c| c["partial"].to_i }
        )
      end

      def line(entries)
        s = call(entries)
        "引用の原文化: 置き換えた #{s.restored}（#{s.restored_segments}座） / 変わらず #{s.unchanged} / 置き換えできず #{s.failed} / 一部だけの引用 #{s.partial}"
      end
    end
  end
end
