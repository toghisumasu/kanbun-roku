# 全会話の区切りを messages から作る。DBへの書き込みは apply: true のときだけ。
# 閉じた区切り（end_reason が open 以外）は更新しない。open の区切りだけ、先頭の発言から計算し直す。
# （閉じた区切りの後ろ＝最後の閉じた区切りより後の発言を、まとめて区切り直す。）
class SegmentRebuilder
  Report = Struct.new(:total, :end_reasons, :per_session, :max_messages, :written, keyword_init: true) do
    def open_count = end_reasons.fetch("open", 0)

    def per_session_stats
      counts = per_session.sort
      return { min: 0, median: 0, max: 0 } if counts.empty?
      mid = counts.size / 2
      median = counts.size.odd? ? counts[mid] : (counts[mid - 1] + counts[mid]) / 2.0
      { min: counts.first, median: median, max: counts.last }
    end
  end

  def self.rebuild!(apply: false, now: Time.current) = new(apply:, now:).call

  def self.report_text(report)
    stats = report.per_session_stats
    [
      "区切りの総数: #{report.total}",
      "end_reason ごと: #{report.end_reasons.sort.to_h}",
      "open: #{report.open_count}",
      "1会話あたりの区切り数: 最小 #{stats[:min]} / 中央値 #{stats[:median]} / 最大 #{stats[:max]}",
      "発言数が最大の区切り: #{report.max_messages} 発言",
      ("書き込んだ区切り: #{report.written}" if report.written.positive?)
    ].compact.join("
")
  end

  def initialize(apply:, now:)
    @apply = apply
    @now = now
  end

  def call
    end_reasons = Hash.new(0)
    per_session = []
    max_messages = 0
    written = 0

    transaction do
      Message.distinct.order(:session_id).pluck(:session_id).each do |session_id|
        kept = Segment.where(session_id:).closed.order(:started_at, :first_message_id).to_a
        last_closed = kept.last

        rebuilt = ConversationSegmenter.call(
          tail_messages(session_id, last_closed), now: @now, previous_end_reason: last_closed&.end_reason
        )

        kept.each do |segment|
          end_reasons[segment.end_reason] += 1
          max_messages = [ max_messages, message_count(segment) ].max
        end
        rebuilt.each do |r|
          end_reasons[r.end_reason] += 1
          max_messages = [ max_messages, r.messages.size ].max
        end
        per_session << kept.size + rebuilt.size

        written += write(session_id, last_closed, rebuilt) if @apply
      end
    end

    Report.new(total: end_reasons.values.sum, end_reasons: end_reasons.to_h, per_session:, max_messages:, written:)
  end

  private
    def transaction(&block)
      @apply ? Segment.transaction(&block) : block.call
    end

    # 最後の閉じた区切りより後の発言（なければ全部）。open の区切りもここに含まれる。
    def tail_messages(session_id, last_closed)
      scope = Message.where(session_id:).order(:occurred_at, :id)
      scope = scope.where("(occurred_at, id) > (?, ?)", last_closed.ended_at, last_closed.last_message_id) if last_closed
      scope.select(:id, :role, :body, :occurred_at).to_a
    end

    def message_count(segment)
      Message.where(session_id: segment.session_id)
             .where("(occurred_at, id) >= (?, ?)", segment.started_at, segment.first_message_id)
             .where("(occurred_at, id) <= (?, ?)", segment.ended_at, segment.last_message_id)
             .count
    end

    def write(session_id, last_closed, rebuilt)
      Segment.where(session_id:).open_ended.delete_all
      previous = last_closed
      rebuilt.each do |r|
        previous = Segment.create!(
          session_id:, segment_date: r.segment_date,
          first_message_id: r.messages.first.id, last_message_id: r.messages.last.id,
          started_at: r.started_at, ended_at: r.ended_at,
          start_reason: r.start_reason, end_reason: r.end_reason, resumed: r.resumed?,
          continued_from: previous
        )
      end
      rebuilt.size
    end
end
