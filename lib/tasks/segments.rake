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

namespace :segments do
  desc "発言の分類・区切りの型・貼付省略の効果の件数（読み取りのみ。本文は出さない）"
  task classify_report: :environment do
    rows = Message.order(:id).pluck(:id, :session_id, :role, :body, :raw)
    by_session = rows.group_by { |_, session_id, *| session_id }
    msg = Struct.new(:role, :body, :raw)
    segments = Segment.order(:id).map do |segment|
      by_session.fetch(segment.session_id)
        .select { |id, *| id.between?(segment.first_message_id, segment.last_message_id) }
        .map { |_, _, role, body, raw| msg.new(role, body, raw) }
    end
    puts ClassificationReport.text(ClassificationReport.build(segments))
  end
end

namespace :segments do
  desc "人間の発言のうち Claude 文の貼り付けの件数と割合（読み取りのみ。既定では本文・一致元は出さない）。SEGMENT=id で、その座の発言ごとの該当・非該当も出す。SHOW=1 を足すと、その発言の置き換え後の本文（印入り、最初の200字）と一致の長さ・割合・残る長さを端末に出す（SEGMENT 必須。AT=HH:MM で絞る）"
  task paste_origin_report: :environment do
    assistant = Struct.new(:body, :occurred_at)
    detector = ClaudePasteDetector.new(Message.where(role: "assistant").pluck(:body, :occurred_at).map { |b, t| assistant.new(b, t) })
    rows = Message.order(:id).pluck(:id, :session_id, :role, :body, :raw, :occurred_at)
    by_session = rows.group_by { |_, session_id, *| session_id }
    per_segment = Segment.order(:id).map do |segment|
      messages = by_session.fetch(segment.session_id).select { |id, *| id.between?(segment.first_message_id, segment.last_message_id) }
      utterances = messages.select { |_, _, role, body, raw| MessageClassifier.classify(role:, body:, raw:) == :utterance && role == "user" && !body.strip.empty? }
      flagged = utterances.select { |_, _, _, body, _, at| detector.paste?(body, before: at) }
      remainders = flagged.map { |_, _, _, body, _, at| detector.remainder_size(body, before: at) }
      moved = flagged.count { |_, _, _, body, _, at| MessageClassifier.prompt_lines?(detector.mask(body, SegmentChunker::CLAUDE_PASTE_MARK, before: at)) }
      { id: segment.id, utterances: utterances.size, flagged: flagged.size, flagged_ids: flagged.map(&:first), messages: messages,
        remainders: remainders, moved_to_paste_text: moved }
    end
    total = per_segment.sum { |s| s[:utterances] }
    hit = per_segment.sum { |s| s[:flagged] }
    puts "人間の発言（utterance、本文あり）: #{total} 件 / Claude 文の貼り付け: #{hit} 件（#{(hit.fdiv(total) * 100).round(2)}%）"
    remainders = per_segment.flat_map { |s| s[:remainders] }
    buckets = { "0字" => 0..0, "1〜9字" => 1..9, "10〜29字" => 10..29, "30〜99字" => 30..99, "100字以上" => 100..Float::INFINITY }
    puts "　一致しない部分が残る長さ（正規化後、該当 #{remainders.size} 件中）: " +
         buckets.map { |label, range| "#{label}=#{remainders.count { |n| range.cover?(n) }}" }.join(" / ")
    puts "　残りがシェルのプロンプト行などを含み、paste_text へ移る件数: #{per_segment.sum { |s| s[:moved_to_paste_text] }}"
    with_hit = per_segment.select { |s| s[:flagged] > 0 }
    with_utt = per_segment.select { |s| s[:utterances] > 0 }
    puts "座: #{per_segment.size} 件中、該当ありは #{with_hit.size} 件（発言のある座 #{with_utt.size} 件に対して #{(with_hit.size.fdiv(with_utt.size) * 100).round(1)}%）"
    puts "座ごとの該当件数の分布: #{per_segment.map { |s| s[:flagged] }.tally.sort.to_h.map { |n, c| "#{n}件=#{c}座" }.join(" / ")}"
    ratios = with_utt.map { |s| s[:flagged].fdiv(s[:utterances]) }.sort
    q = ->(p) { ratios[((ratios.size - 1) * p).round].round(3) }
    puts "座ごとの該当率（発言のある座）: p50=#{q.(0.5)} p75=#{q.(0.75)} p90=#{q.(0.9)} max=#{ratios.last.round(3)}"
    puts "該当が多い座（id: 該当/発言）: " + with_hit.sort_by { |s| -s[:flagged] }.first(10).map { |s| "#{s[:id]}: #{s[:flagged]}/#{s[:utterances]}" }.join(" / ")

    abort "SHOW=1 には SEGMENT=id が必要です" if ENV["SHOW"] == "1" && ENV["SEGMENT"].nil?

    if ENV["SEGMENT"]
      seg = per_segment.find { |s| s[:id] == ENV["SEGMENT"].to_i } or abort "区切りが見つかりません"
      puts "座#{seg[:id]}: 人間の発言 #{seg[:utterances]} 件、該当 #{seg[:flagged]} 件"
      seg[:messages].each do |id, _, role, body, raw, at|
        next unless role == "user"

        stamp = at.in_time_zone(ConversationSegmenter::JST).strftime("%H:%M")
        next unless ENV["AT"].nil? || stamp == ENV["AT"]

        kind = MessageClassifier.classify(role:, body:, raw:)
        verdict = kind == :utterance && !body.strip.empty? ? (detector.paste?(body, before: at) ? "該当" : "非該当") : "対象外(#{kind})"
        puts "  #{stamp} #{verdict}"
        next unless ENV["SHOW"] == "1"

        if body.strip.empty?
          puts "    （本文なし）"
        else
          info = detector.analyze(body, before: at)
          puts "    一致の長さ #{info.match_length} 字 / 発言（正規化後）#{info.size} 字 / 一致割合 #{(info.ratio * 100).round(1)}%"
          shown = kind == :utterance && detector.paste?(body, before: at) ? detector.mask(body, SegmentChunker::CLAUDE_PASTE_MARK, before: at) : body
          puts "    発言の残る部分 #{detector.remainder_size(body, before: at)} 字（一致部分を除く、正規化後）"
          puts "    置き換え後の本文（最初の200字）: #{shown[0, 200]}#{"…" if shown.size > 200}"
        end
      end
    end
  end
end
