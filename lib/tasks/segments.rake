namespace :segments do
  desc "会話の区切りを作る。閉じた区切りは更新せず、open の区切りだけ計算し直す。既定は dry-run。実書き込みは APPLY=1"
  task rebuild: :environment do
    apply = ENV["APPLY"] == "1"
    puts "#{apply ? "実書き込み" : "dry-run（DBには書かない）"}: 区切りの再計算"
    puts SegmentRebuilder.report_text(SegmentRebuilder.rebuild!(apply: apply))
  end
end

namespace :segments do
  desc "曽良モードの入力の塊分けを全区切りで試す（読み取りのみ。本文は出さない）"
  task chunk_report: :environment do
    messages_by_id = Message.order(:id).pluck(:id, :session_id, :role, :body)
    by_session = messages_by_id.group_by { |_, session_id, _, _| session_id }
    msg = Struct.new(:role, :body)
    results = Segment.order(:id).map do |segment|
      rows = by_session.fetch(segment.session_id).select { |id, *| id.between?(segment.first_message_id, segment.last_message_id) }
      SegmentChunker.call(rows.map { |_, _, role, body| msg.new(role, body) })
    end
    puts SegmentChunkReport.text(SegmentChunkReport.summarize(results))
  end
end
