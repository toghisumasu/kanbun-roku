namespace :segments do
  desc "会話の区切りを作る。閉じた区切りは更新せず、open の区切りだけ計算し直す。既定は dry-run。実書き込みは APPLY=1"
  task rebuild: :environment do
    apply = ENV["APPLY"] == "1"
    puts "#{apply ? "実書き込み" : "dry-run（DBには書かない）"}: 区切りの再計算"
    puts SegmentRebuilder.report_text(SegmentRebuilder.rebuild!(apply: apply))
  end
end
