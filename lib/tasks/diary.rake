# ダイアリー生成（第1段階：A のみ）の運用タスク。
# diary:dry_run と diary:report は読み取りのみ。diary:enqueue と diary:retry_failed は、APPLY=1 を付けたときだけジョブを投入する。
# 出力は件数と秒数だけ（ログの本文は出さない）。
namespace :diary do
  # 1塊あたりの秒数（A）。sora9 の実測（14区間・19塊）で約44.7秒。最初の100座の実測で見直す。
  SECONDS_PER_CHUNK = ENV.fetch("SECONDS_PER_CHUNK", "44.7").to_f

  def diary_hours(seconds) = (seconds / 3600.0).round(1)

  def diary_percentile(values, fraction)
    sorted = values.sort
    sorted.empty? ? nil : sorted[((sorted.size - 1) * fraction).round]
  end

  def diary_distribution(counts) = counts.tally.sort.to_h.map { |n, c| "#{n}塊=#{c}" }.join(" / ")

  # 閉じた座すべての、A の入力（塊）を作る。
  def diary_build_all(detector:, limit: SegmentChunker::INPUT_LIMIT)
    Segment.closed.order(:segment_date, :id).map { |segment| Diary::InputBuilder.call(segment, detector:, limit:) }
  end

  def diary_input_tokens(built) = built.chunks.sum(&:tokens)

  def diary_plan(built)
    descriptors = built.reject(&:empty?).map do |b|
      Diary::SamplePlanner::Descriptor.new(
        id: b.segment.id, segment_date: b.segment.segment_date, input_tokens: diary_input_tokens(b), type: b.type,
        a_lines: Diary::Coverage.count(b.human_messages.map(&:text))[:a_lines].positive?
      )
    end
    Diary::SamplePlanner.call(descriptors)
  end

  def diary_up_to_date?(segment, built, model)
    entry = DiaryEntry.find_by(segment_id: segment.id)
    entry && entry.model == model && entry.prompt_version == Diary::Prompts::A::PROMPT_VERSION &&
      entry.rule_version == Diary::Rules::VERSION && entry.input_digest == built.digest
  end

  desc "LLM を呼ばずに、入力の上限・塊の数・時間の見込み・最初の100座の計画を出す（読み取りのみ）"
  task dry_run: :environment do
    detector = Diary::DetectorCache.fetch
    instruction_tokens = SegmentChunker.estimate_tokens(Diary::Prompts::A::INSTRUCTION)
    limit = SegmentChunker::INPUT_LIMIT
    built = diary_build_all(detector:)
    with_input = built.reject(&:empty?)
    chunks = with_input.sum { |b| b.chunks.size }
    total_seconds = chunks * SECONDS_PER_CHUNK

    puts "入力の上限（INPUT_LIMIT）: #{limit} トークン = num_ctx #{SegmentChunker::CONTEXT} − 指示文 #{instruction_tokens}（見積もり）" \
         " − テンプレート #{SegmentChunker::TEMPLATE_RESERVE} − 出力 #{SegmentChunker::OUTPUT_RESERVE}（A の num_predict）を、100単位で切り捨て"
    puts "座: closed #{built.size} 件 / open #{Segment.open_ended.count} 件（open には作らない）"
    puts "人間の発言がなく、生成しない座: #{built.size - with_input.size} 件"
    puts "座の型: " + with_input.map(&:type).tally.sort.map { |t, c| "#{t}=#{c}" }.join(" / ")
    puts "塊の数（A の入力＝人間の発言ブロックのみ、人間の発言の分だけで数える）: 合計 #{chunks} 塊（#{diary_distribution(with_input.map { |b| b.chunks.size })}）"
    puts "最大の塊: #{with_input.flat_map { |b| b.chunks.map(&:tokens) }.max} トークン（上限 #{limit}）"
    puts "時間の見込み（1塊 #{SECONDS_PER_CHUNK} 秒）: #{total_seconds.round} 秒 = #{diary_hours(total_seconds)} 時間（呼び出し #{chunks} 回）"

    # 参考: 塊の分け方・出力の確保分を変えたときの塊数（同じメッセージを読み直す）。
    alt_limit = (((SegmentChunker::CONTEXT - instruction_tokens - SegmentChunker::TEMPLATE_RESERVE - 1_200) / 100) * 100)
    combined = 0
    alt = 0
    Segment.closed.find_each do |segment|
      messages = Diary::InputBuilder.messages_for(segment)
      combined += SegmentChunker.call(messages, limit:, human_block: true, claude_paste: detector).chunks.size
      alt += SegmentChunker.call(messages, limit: alt_limit, human_block: true, flow: false, claude_paste: detector).chunks.size
    end
    puts "参考: 人間の発言ブロック＋流れで分けた場合（同じ上限 #{limit}）: #{combined} 塊 = #{diary_hours(combined * SECONDS_PER_CHUNK)} 時間"
    puts "参考: num_predict を1,200に下げた場合（上限 #{alt_limit}）: #{alt} 塊 = #{diary_hours(alt * SECONDS_PER_CHUNK)} 時間"
    puts "参考: 以前の見込み（942塊 × 44.7秒）= #{diary_hours(942 * 44.7)} 時間"

    plan = diary_plan(built)
    by_id = with_input.to_h { |b| [ b.segment.id, b ] }
    tokens = ->(ids) { ids.map { |id| diary_input_tokens(by_id[id]) } }
    mean = ->(values) { values.empty? ? 0 : (values.sum.to_f / values.size).round }
    median = ->(values) { diary_percentile(values, 0.5) }
    block_chunks = plan.first_block.sum { |id| by_id[id].chunks.size }
    puts "最初の塊（時期4×型2×入力の大きさ3で層別した標本 #{plan.sample.size} ＋ 入力が最大級 #{plan.largest.size} ＋「A:」行 #{plan.a_line_picks.size}" \
         " ＝ #{plan.first_block.size} 座、seed #{Diary::SamplePlanner::SEED}）: 塊 #{block_chunks} 個、時間の見込み #{diary_hours(block_chunks * SECONDS_PER_CHUNK)} 時間"
    all_tokens = tokens.(with_input.map { |b| b.segment.id })
    puts "入力トークン（座ごと、平均 / 中央値 / 最大）: 全座 #{mean.(all_tokens)} / #{median.(all_tokens)} / #{all_tokens.max}" \
         " ・ 標本 #{mean.(tokens.(plan.sample))} / #{median.(tokens.(plan.sample))} / #{tokens.(plan.sample).max}"
    puts "標本の型: #{plan.sample.map { |id| by_id[id].type }.tally.sort.map { |t, c| "#{t}=#{c}" }.join(" / ")}（全座 #{with_input.map(&:type).tally.sort.map { |t, c| "#{t}=#{c}" }.join(" / ")}）"
    puts "最大級の座（id: 入力トークン）: #{plan.largest.map { |id| "#{id}: #{diary_input_tokens(by_id[id])}" }.join(" / ")}"
    puts "「A:」行の座（id）: #{plan.a_line_picks.sort.inspect}（「A:」行を含む座は全部で #{with_input.count { |b| Diary::Coverage.count(b.human_messages.map(&:text))[:a_lines].positive? }} 座）"
    puts "層ごとの標本の数/層の大きさ（時期0〜3の合計。入力の大きさ 0=小 1=中 2=大）:"
    plan.strata.group_by { |(_, type, size), _| [ size, type ] }.sort.each do |(size, type), entries|
      puts "  入力の大きさ #{size}, #{type}: #{entries.sum { |_, (picked, _)| picked }}/#{entries.sum { |_, (_, total)| total }}（時期ごと #{entries.sort.map { |(period, _, _), (picked, _)| picked }.join("・")}）"
    end
  end

  desc "生成する座の順序（最初の塊は層別の標本＋最大級＋「A:」行の座、残りは古い順）に従って、ジョブを投入する。" \
       "LIMIT=件数（既定100）。SEGMENTS=1,2,3 で座を指定すると、その座だけ（順序・LIMIT は使わない）。APPLY=1 のときだけ投入"
  task enqueue: :environment do
    apply = ENV["APPLY"] == "1"
    model = ENV.fetch("DIARY_MODEL", Diary::OllamaClient::DEFAULT_MODEL)
    detector = Diary::DetectorCache.fetch

    if ENV["SEGMENTS"].present?
      ids = ENV["SEGMENTS"].split(",").map(&:strip).reject(&:empty?).map(&:to_i).uniq
      segments = Segment.closed.where(id: ids).index_by(&:id)
      built = ids.filter_map { |id| segments[id] && Diary::InputBuilder.call(segments[id], detector:) }.index_by { |b| b.segment.id }
      invalid = ids.reject { |id| built[id] && !built[id].empty? }
      abort "投入できない座: #{invalid.inspect}（存在しない・closed でない・人間の発言がない）" if invalid.any?

      todo = ids.reject { |id| diary_up_to_date?(built[id].segment, built[id], model) }
      puts "#{apply ? "投入" : "dry-run（投入しない）"}: 指定した #{ids.size} 座のうち #{todo.size} 座（生成済みを除く）、塊 #{todo.sum { |id| built[id].chunks.size }} 個"
      puts "  座 #{todo.inspect}"
      todo.each { |id| GenerateDiaryJob.perform_later(id) } if apply
      next
    end

    limit = ENV.fetch("LIMIT", "100").to_i
    built = diary_build_all(detector:)
    by_id = built.to_h { |b| [ b.segment.id, b ] }
    plan = diary_plan(built)
    todo = plan.order.reject { |id| diary_up_to_date?(by_id[id].segment, by_id[id], model) }.first(limit)
    puts "#{apply ? "投入" : "dry-run（投入しない）"}: 順序の先頭から #{todo.size} 座（生成済みを除く、LIMIT=#{limit}）、塊 #{todo.sum { |id| by_id[id].chunks.size }} 個"
    todo.each { |id| GenerateDiaryJob.perform_later(id) } if apply
  end

  desc "失敗した塊のある座を、ジョブに再投入する。APPLY=1 のときだけ投入"
  task retry_failed: :environment do
    ids = DiaryChunk.failed.distinct.pluck(:segment_id).sort
    ids -= DiaryEntry.where(segment_id: ids).pluck(:segment_id)
    puts "#{ENV["APPLY"] == "1" ? "再投入" : "dry-run（投入しない）"}: 失敗した塊のある座 #{ids.size} 件"
    ids.each { |id| GenerateDiaryJob.perform_later(id) } if ENV["APPLY"] == "1"
  end

  desc "生成の結果の件数（時間・失敗・モデルの digest・引用の合格率・決定の取りこぼし・リンク）。読み取りのみ"
  task report: :environment do
    chunks = DiaryChunk.all.to_a
    entries = DiaryEntry.all.to_a
    puts "ダイアリー: #{entries.size} 座 / 塊の記録: " + DiaryChunk::STATUSES.map { |s| "#{s}=#{chunks.count { |c| c.status == s }}" }.join(" ")
    puts "規則の版: #{entries.map(&:rule_version).tally} / プロンプトの版: #{entries.map(&:prompt_version).tally} / モデル: #{entries.map(&:model).tally}"

    # 失敗（基準：再試行後の失敗が2%未満）
    tried = chunks.map(&:segment_id).uniq.size
    failed_segments = chunks.select { |c| c.status == "failed" }.map(&:segment_id).uniq.size
    retried = chunks.count { |c| c.attempts > 1 }
    puts "別の seed で再試行した塊: #{retried} / 再試行後も failed の塊: #{chunks.count { |c| c.status == "failed" }}（塊の記録 #{chunks.size} 件中）"
    puts "失敗した座: #{failed_segments} / 試行した座 #{tried}（#{tried.zero? ? "-" : "#{(failed_segments * 100.0 / tried).round(1)}%"}。基準は2%未満）"
    puts "失敗の種類: #{chunks.select { |c| c.status == "failed" }.map(&:error_kind).tally}"

    # モデルの digest（冪等の鍵には含めない。混ざっていないかの警告）
    chunks.group_by(&:model).each do |model, group|
      digests = group.map(&:model_digest).tally
      puts "モデル #{model}: digest #{digests.map { |d, n| "#{d ? d[0, 12] : "(なし)"}=#{n}" }.join(" ")}"
      puts "  警告: モデル #{model} の digest が複数混ざっています（実行の途中でモデルが入れ替わった可能性）" if digests.keys.compact.size > 1
      puts "  警告: モデル #{model} に digest が記録されていない塊が混ざっています" if digests.key?(nil) && digests.keys.compact.any?
    end
    puts "警告: モデルが複数混ざっています（#{chunks.map(&:model).uniq.join(", ")}）" if chunks.map(&:model).uniq.size > 1

    # 時間・トークン
    done = chunks.select { |c| c.status == "succeeded" && c.total_duration_ms }
    seconds = done.map { |c| c.total_duration_ms / 1000.0 }
    unless seconds.empty?
      puts "1塊あたりの秒数: 平均 #{(seconds.sum / seconds.size).round(1)} / 中央値 #{diary_percentile(seconds, 0.5).round(1)} / p90 #{diary_percentile(seconds, 0.9).round(1)} / 最大 #{seconds.max.round(1)}（見込み #{SECONDS_PER_CHUNK}）"
      puts "出力トークン（eval_count）: 最大 #{done.map(&:eval_count).compact.max} / p99 #{diary_percentile(done.map(&:eval_count).compact, 0.99)}（num_predict #{Diary::Prompts::A::OPTIONS[:num_predict]}）"
      peak = done.map(&:prompt_eval_count).compact.max
      puts "入力トークン（prompt_eval_count）: 最大 #{peak}（num_ctx #{Diary::Prompts::A::OPTIONS[:num_ctx]} の #{(peak * 100.0 / Diary::Prompts::A::OPTIONS[:num_ctx]).round(1)}%）"
    end

    # 引用の検証
    totals = Hash.new(0)
    entries.each { |e| e.validation.fetch("counts", {}).each { |k, v| totals[k] += v } }
    unless totals.empty?
      puts "引用の検証: 項目 #{totals["total"]} / 合格 #{totals["pass"]}（#{(totals["pass"] * 100.0 / totals["total"]).round(1)}%） / 不合格 #{totals["fail"]}" \
           "（引用なし #{totals["no_quote"]}・入力にない #{totals["not_in_input"]}・逆の発言者 #{totals["wrong_label"]}・短い断片 #{totals["short_fragment"]}・印入り #{totals["mark_in_quote"]}）/ 免除 #{totals["exempt"]}"
    end

    # 後処理・リンク
    puts "後処理: 再分類（c）で移した #{entries.sum { |e| e.validation["moved"].to_i }} / 重複で落とした #{entries.sum { |e| e.validation.dig("dropped", "count").to_i }}"
    items = entries.sum { |e| e.note.values.sum(&:size) }
    links = DiaryLink.group(:link_kind).count
    decisions = entries.sum { |e| e.note.fetch("決定", []).size }
    puts "リンク: 項目 #{items} 件に対し source #{links.fetch("source", 0)} 件（#{items.zero? ? "-" : "#{(links.fetch("source", 0) * 100.0 / items).round(1)}%"}、引用が空の項目は付かない）" \
         " / 決定 #{decisions} 件に対し候補 #{links.fetch("preceding_assistant_candidate", 0)} 件 / リンクが付かなかった項目 #{entries.sum { |e| e.validation.fetch("unmatched_links", []).size }}"

    # 決定の取りこぼし（機械的な見落とし検査）
    unless entries.empty?
      detector = Diary::DetectorCache.fetch
      missed = []
      no_marker = 0
      entries.each do |entry|
        built = Diary::InputBuilder.call(entry.segment, detector:)
        found = Diary::Coverage.count(built.human_messages.map(&:text))
        decision_count = entry.note.fetch("決定", []).size
        missed << entry.segment_id if (found[:decision_words] + found[:a_lines]).positive? && decision_count.zero?
        no_marker += 1 if (found[:decision_words] + found[:a_lines]).zero? && decision_count.positive?
      end
      puts "決定語または「A:」行があるのに決定が0の座: #{missed.size} / #{entries.size} #{missed.first(30).inspect}"
      puts "決定語も「A:」行もないのに決定項目がある座: #{no_marker}"
    end
  end
end
