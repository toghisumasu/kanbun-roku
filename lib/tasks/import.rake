namespace :import do
  desc "claude.ai のエクスポート（conversations.json）を取り込む。既定は dry-run。実取り込みは APPLY=1"
  task :claude_ai, [ :path ] => :environment do |_, args|
    path = args[:path] || Rails.root.join("data/export/conversations-000/conversations.json").to_s
    apply = ENV["APPLY"] == "1"

    puts "#{apply ? "実取り込み" : "dry-run（DBには書かない）"}: #{path}"
    r = ClaudeAiExport::Importer.new(path, apply: apply).call

    puts "会話: #{r.conversations}（発言0件: #{r.empty_conversations}）"
    puts "発言: #{r.messages}"
    puts "取り込む: #{r.to_import}（うち body が空: #{r.body_empty}）"
    puts "取り込み済みでスキップ: #{r.already_imported}"
    puts "不正でスキップ: #{r.skipped.values.sum} #{r.skipped.to_h}"
    puts "raw の NUL を置換した発言: #{r.raw_nul_replaced}"
    puts "実際に挿入: #{r.inserted}" if apply

    # 開いた区切りの更新用。閉じた区切りは更新されない。
    if apply
      puts "区切りを再計算"
      puts SegmentRebuilder.report_text(SegmentRebuilder.rebuild!(apply: true))
    end
  end
end
