module Diary
  # 見落とし検査を、ダイアリーのある座ごとに走らせる。読み取りのみ（本文は返さない。座のidだけ）。
  module CoverageScan
    Result = Struct.new(:narrow_missed, :broad_missed, :broad_only_missed, :no_marker, keyword_init: true)

    class << self
      # narrow_missed: 決定語（狭い）または「A:」行があるのに決定が0の座のid
      # broad_missed: 広い目印または「A:」行があるのに決定が0の座のid
      # broad_only_missed: 広い目印だけが反応する（狭い目印も「A:」行も反応しない）決定0の座のid
      # no_marker: 決定語も「A:」行もないのに決定項目がある座の数（狭い目印）
      def call(entries, detector: Diary::DetectorCache.fetch)
        result = Result.new(narrow_missed: [], broad_missed: [], broad_only_missed: [], no_marker: 0)
        entries.each do |entry|
          found = Coverage.count(Diary::InputBuilder.call(entry.segment, detector:).human_messages.map(&:text))
          decisions = entry.note.fetch("決定", []).size
          narrow = (found[:decision_words] + found[:a_lines]).positive?
          broad = (found[:broad_decision_words] + found[:a_lines]).positive?
          if decisions.zero?
            result.narrow_missed << entry.segment_id if narrow
            result.broad_missed << entry.segment_id if broad
            result.broad_only_missed << entry.segment_id if broad && !narrow
          else
            result.no_marker += 1 unless narrow
          end
        end
        result
      end
    end
  end
end
