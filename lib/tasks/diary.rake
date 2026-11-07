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

  # 今の版の塊の記録が、すべて成功でそろっているか（CHUNKS_ONLY=1 の「生成済み」の判定）。
  def diary_chunks_done?(built, model)
    built.chunks.all? do |chunk|
      DiaryChunk.succeeded.exists?(segment_id: built.segment.id, chunk_index: chunk.index, input_digest: chunk.digest, model:,
                                   prompt_version: Diary::Prompts::A::PROMPT_VERSION)
    end
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
       "LIMIT=件数（既定100）。SEGMENTS=1,2,3 で座を指定すると、その座だけ（順序・LIMIT は使わない）。" \
       "CHUNKS_ONLY=1 だと、塊の記録（diary_chunks）だけを作り、DiaryEntry は上書きしない（新しい版の比較用。diary:compare で比べる）。APPLY=1 のときだけ投入"
  task enqueue: :environment do
    apply = ENV["APPLY"] == "1"
    chunks_only = ENV["CHUNKS_ONLY"] == "1"
    model = ENV.fetch("DIARY_MODEL", Diary::OllamaClient::DEFAULT_MODEL)
    detector = Diary::DetectorCache.fetch
    done = ->(built) { chunks_only ? diary_chunks_done?(built, model) : diary_up_to_date?(built.segment, built, model) }
    mode = chunks_only ? "（塊の記録だけ。DiaryEntry は変えない）" : ""

    if ENV["SEGMENTS"].present?
      ids = ENV["SEGMENTS"].split(",").map(&:strip).reject(&:empty?).map(&:to_i).uniq
      segments = Segment.closed.where(id: ids).index_by(&:id)
      built = ids.filter_map { |id| segments[id] && Diary::InputBuilder.call(segments[id], detector:) }.index_by { |b| b.segment.id }
      invalid = ids.reject { |id| built[id] && !built[id].empty? }
      abort "投入できない座: #{invalid.inspect}（存在しない・closed でない・人間の発言がない）" if invalid.any?

      todo = ids.reject { |id| done.(built[id]) }
      puts "#{apply ? "投入" : "dry-run（投入しない）"}#{mode}: 指定した #{ids.size} 座のうち #{todo.size} 座（生成済みを除く）、塊 #{todo.sum { |id| built[id].chunks.size }} 個"
      puts "  座 #{todo.inspect}"
      todo.each { |id| GenerateDiaryJob.perform_later(id, chunks_only:) } if apply
      next
    end

    limit = ENV.fetch("LIMIT", "100").to_i
    built = diary_build_all(detector:)
    by_id = built.to_h { |b| [ b.segment.id, b ] }
    plan = diary_plan(built)
    todo = plan.order.reject { |id| done.(by_id[id]) }.first(limit)
    puts "#{apply ? "投入" : "dry-run（投入しない）"}#{mode}: 順序の先頭から #{todo.size} 座（生成済みを除く、LIMIT=#{limit}）、塊 #{todo.sum { |id| by_id[id].chunks.size }} 個"
    todo.each { |id| GenerateDiaryJob.perform_later(id, chunks_only:) } if apply
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
    dropped = entries.select { |e| e.validation.to_h["sensitive_dropped"].to_i.positive? }
    puts "機微情報の除外（g）で落とした項目: #{dropped.sum { |e| e.validation["sensitive_dropped"].to_i }} 件 / #{dropped.size} 座 #{dropped.map(&:segment_id).sort.inspect}"
    moves = entries.map { |e| e.validation.to_h["moved_by_rule"] }.compact
    puts "再分類の規則別の移動数: #{%w[ c d e f ].to_h { |r| [ r, moves.sum { |m| m[r].to_i } ] }}" if moves.any?
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
           "（引用なし #{totals["no_quote"]}・入力にない #{totals["not_in_input"]}・逆の発言者 #{totals["wrong_label"]}・短い断片 #{totals["short_fragment"]}・印入り #{totals["mark_in_quote"]}）"
      puts "免除（引用が空）: #{totals["exempt"] + totals["exempt_paraphrase"]} 件 = 免除語そのもの #{totals["exempt"]} / 言い換え #{totals["exempt_paraphrase"]}（total に入れない）"
    end

    # 後処理・リンク
    puts "後処理: 再分類（c）で移した #{entries.sum { |e| e.validation["moved"].to_i }} / 決定語のため移さなかった #{entries.sum { |e| e.validation["kept_decision_word"].to_i }} / 重複で落とした #{entries.sum { |e| e.validation.dig("dropped", "count").to_i }}"
    puts Diary::QuoteRestoreSummary.line(entries)
    items = entries.sum { |e| e.note.values.sum(&:size) }
    links = DiaryLink.group(:link_kind).count
    decisions = entries.sum { |e| e.note.fetch("決定", []).size }
    puts "リンク: 項目 #{items} 件に対し source #{links.fetch("source", 0)} 件（#{items.zero? ? "-" : "#{(links.fetch("source", 0) * 100.0 / items).round(1)}%"}、引用が空の項目は付かない）" \
         " / 決定 #{decisions} 件に対し候補 #{links.fetch("preceding_assistant_candidate", 0)} 件 / リンクが付かなかった項目 #{entries.sum { |e| e.validation.fetch("unmatched_links", []).size }}"

    # 決定の取りこぼし（機械的な見落とし検査）
    unless entries.empty?
      scan = Diary::CoverageScan.call(entries)
      puts "決定語または「A:」行があるのに決定が0の座: 狭い #{scan.narrow_missed.size} / 広い #{scan.broad_missed.size}（広い目印だけ #{scan.broad_only_missed.size}）/ #{entries.size} #{scan.narrow_missed.first(30).inspect}"
      puts "決定語も「A:」行もないのに決定項目がある座: #{scan.no_marker}"
    end
  end

  desc "目視用：決定0の座のidだけを出す（本文は出さない）。決定語ありの10座と、広い目印だけが反応する10座。読み取りのみ。N=10 で件数を変える"
  task missed_ids: :environment do
    n = (ENV["N"] || 10).to_i
    scan = Diary::CoverageScan.call(DiaryEntry.includes(:segment).to_a)
    puts "決定語ありで決定0（狭い）#{scan.narrow_missed.size}座のうち先頭#{n}座: #{scan.narrow_missed.first(n).inspect}"
    puts "広い目印だけが反応する決定0 #{scan.broad_only_missed.size}座のうち先頭#{n}座: #{scan.broad_only_missed.first(n).inspect}"
  end

  # 見出しごとの項目を表示する。items: 見出し => [[本文, 引用], ...]。links: item_key => [LinkSpec 相当（message_id, link_kind）]。
  def diary_print_items(items, links)
    items.each do |heading, list|
      puts "", "■ #{heading}（#{list.size}件）"
      list.each_with_index do |(text, quote), index|
        key = Diary::DecisionLinker.item_key(heading, index)
        puts "  [#{key}] #{text}"
        puts "    引用: #{quote.presence || "(なし)"}"
        item_links = links.fetch(key, [])
        sources = item_links.select { |l| l.link_kind == "source" }.map(&:message_id)
        candidates = item_links.select { |l| l.link_kind == "preceding_assistant_candidate" }.map(&:message_id)
        puts "    リンク: source #{sources.empty? ? "-" : sources.join(", ")} / 候補 #{candidates.empty? ? "-" : candidates.join(", ")}"
      end
    end
  end

  desc "SEGMENT=座のid の、ダイアリー項目を見出しごとに表示する（本文・引用・リンクの message_id）。読み取りのみ。" \
       "VERSION=プロンプトの版 を付けると、その版の塊の記録から組み立てて表示する（diary_entries は見ない・変えない。DIARY_MODEL でモデルを指定）。" \
       "VERSION と MOVED=1 を付けると、後処理で決定から移った項目だけを、規則名つきで表示する"
  task show: :environment do
    abort "SEGMENT=座のid を指定してください" if ENV["SEGMENT"].blank?
    segment = Segment.find_by(id: ENV["SEGMENT"].to_i) or abort "座 #{ENV["SEGMENT"]} がありません"

    if ENV["VERSION"].present?
      model = ENV.fetch("DIARY_MODEL", Diary::OllamaClient::DEFAULT_MODEL)
      r = Diary::VersionOutputs.call(segment, detector: Diary::DetectorCache.fetch, model:, prompt_version: ENV["VERSION"]) or
        abort "座 #{segment.id}: 版 #{ENV["VERSION"]}（モデル #{model}）の塊の記録がそろっていません"
      puts "座 #{segment.id} / 版 #{ENV["VERSION"]} / モデル #{model} / 規則 #{Diary::Rules::VERSION}（塊から組み立てた表示。diary_entries は変更していない）"
      if ENV["MOVED"] == "1"
        puts "■ 後処理で決定から移った項目（規則 c/d/e/f）と、機微情報で落とした件数 #{r.post.sensitive.size}"
        r.post.moved.each do |before, after|
          rule = Diary::PostProcessor.move_rule(before)
          puts "  [#{rule}] 決定→#{after.heading}", "    #{before.text}", "    引用: #{before.quote.presence || "(なし)"}"
        end
        next
      end
      items = r.outputs.items.transform_values { |list| list.map { |item| [ item.text, item.quote ] } }
      diary_print_items(items, r.outputs.links.group_by(&:item_key))
      next
    end

    entry = DiaryEntry.find_by(segment_id: segment.id) or abort "座 #{segment.id} のダイアリーはまだありません"
    puts "座 #{segment.id} / #{entry.entry_date} / モデル #{entry.model} / プロンプト #{entry.prompt_version} / 規則 #{entry.rule_version} / 生成 #{entry.generated_at}"
    items = entry.note.transform_values { |list| list.map { |item| [ item["本文"], item["引用"] ] } }
    diary_print_items(items, entry.diary_links.order(:id).group_by(&:item_key))
  end

  # 版ごとの要約（件数だけ）。塊の記録がそろっていなければ nil。
  DiaryVersionSummary = Struct.new(:pre, :post, :moved, :kept, :dedupe_dropped, :counts, :src, :cand, :restore_failed, :partial, :by_rule, :sensitive, keyword_init: true)

  def diary_version_summary(segment, detector, model, version)
    r = Diary::VersionOutputs.call(segment, detector:, model:, prompt_version: version) or return nil
    restore = r.outputs.validation["quote_restore"]
    DiaryVersionSummary.new(
      pre: r.notes.sum { |n| n.fetch("決定").size }, post: r.post.items.fetch("決定").size,
      moved: r.post.moved.size, kept: r.post.kept.size, dedupe_dropped: r.post.dropped.count { |item, _| item.heading == "決定" },
      counts: r.post.counts, src: r.outputs.links.count { |l| l.link_kind == "source" },
      cand: r.outputs.links.count { |l| l.link_kind == "preceding_assistant_candidate" },
      restore_failed: restore["failed"], partial: restore["partial"], by_rule: r.post.moved_by_rule, sensitive: r.post.sensitive.size
    )
  end

  desc "SEGMENTS=1,2,3 の座について、旧版（FROM、既定 A-2026-11-02.1）と新版（TO、既定は今の版）を、保存済みの塊の記録から組み立てて、" \
       "件数だけ並べる（決定は後処理(c)の前／後）。読み取りのみ。DIARY_MODEL でモデルを指定。本文は出さない"
  task compare: :environment do
    abort "SEGMENTS=1,2,3 を指定してください" if ENV["SEGMENTS"].blank?
    ids = ENV["SEGMENTS"].split(",").map { |v| v.strip.to_i }.uniq
    model = ENV.fetch("DIARY_MODEL", Diary::OllamaClient::DEFAULT_MODEL)
    from = ENV.fetch("FROM", "A-2026-11-02.1")
    to = ENV.fetch("TO", Diary::Prompts::A::PROMPT_VERSION)
    detector = Diary::DetectorCache.fetch
    describe = lambda do |s|
      next "塊の記録なし" unless s

      "決定 前#{s.pre}→後#{s.post}（移動#{s.moved}[#{s.by_rule.map { |k, v| "#{k}#{v}" }.join(" ")}] 語で残す#{s.kept} 重複落ち#{s.dedupe_dropped} 機微除外#{s.sensitive}）" \
        " / 依頼#{s.counts["人間の依頼・共有"]} 考え#{s.counts["人間の考え"]} 未解決#{s.counts["未解決"]}" \
        " / source#{s.src} 候補#{s.cand} / 原文化失敗#{s.restore_failed} partial#{s.partial}"
    end

    puts "比較（読み取りのみ）: 旧 #{from} / 新 #{to} / モデル #{model} / 座 #{ids.size}"
    totals = { from: Hash.new(0), to: Hash.new(0) }
    shifts = Hash.new { |h, k| h[k] = [] }
    ids.each do |id|
      segment = Segment.find_by(id:)
      unless segment
        puts "座 #{id}: 座がありません"
        next
      end
      old = diary_version_summary(segment, detector, model, from)
      new = diary_version_summary(segment, detector, model, to)
      puts "座 #{id}", "  旧: #{describe.(old)}", "  新: #{describe.(new)}"
      next unless old && new

      { from: old, to: new }.each do |key, s|
        totals[key]["pre"] += s.pre
        totals[key]["post"] += s.post
        totals[key]["moved"] += s.moved
      end
      shifts[:zero_to_some] << id if old.post.zero? && new.post.positive?
      shifts[:some_to_zero] << id if old.post.positive? && new.post.zero?
      shifts[:fewer] << id if new.post < old.post
    end
    puts "合計（両方の版がそろった座）: 旧 決定 c前#{totals[:from]["pre"]}→c後#{totals[:from]["post"]}（移動#{totals[:from]["moved"]}）" \
         " / 新 決定 c前#{totals[:to]["pre"]}→c後#{totals[:to]["post"]}（移動#{totals[:to]["moved"]}）"
    puts "決定 0→1以上の座: #{shifts[:zero_to_some].inspect} / 1以上→0の座: #{shifts[:some_to_zero].inspect} / 決定が減った座: #{shifts[:fewer].inspect}"
  end

  desc "既存のダイアリーを、保存済みの A の出力（diary_chunks）から組み立て直す。LLM は呼ばない。" \
       "SEGMENTS=1,2,3 で座を指定（省略すると、ダイアリーのある全座）。VERSION=プロンプトの版（既定は今の版。旧版を指定すると旧版に戻せる）。" \
       "APPLY=1 のときだけ書き込む。件数だけ表示する"
  task reassemble: :environment do
    apply = ENV["APPLY"] == "1"
    version = ENV.fetch("VERSION", Diary::Prompts::A::PROMPT_VERSION)
    ids = ENV["SEGMENTS"].present? ? ENV["SEGMENTS"].split(",").map { |v| v.strip.to_i }.uniq : DiaryEntry.order(:segment_id).pluck(:segment_id)
    detector = Diary::DetectorCache.fetch
    puts "#{apply ? "書き込み" : "dry-run（書き込まない）"}: #{ids.size} 座 / 版 #{version}"
    tally = Hash.new(0)
    ids.each do |id|
      segment = Segment.find_by(id:)
      unless segment
        puts "座 #{id}: 座がありません"
        next
      end
      r = Diary::Reassembler.call(segment, detector:, apply:, prompt_version: version)
      tally[r.status] += 1
      if r.before
        b = r.before
        a = r.after
        puts "座 #{id} [#{r.status}] 項目 #{b.items}→#{a.items} / source #{b.links_source}→#{a.links_source} / 候補 #{b.links_candidate}→#{a.links_candidate}" \
             " / 引用が原文の部分文字列 #{b.quote_exact}→#{a.quote_exact} / 置き換えた #{a.restored} / quote_partial #{a.quote_partial} / 置き換えできなかった #{a.restore_failed}"
      else
        puts "座 #{id} [#{r.status}]"
      end
    end
    puts "結果: #{tally.sort.map { |k, v| "#{k}=#{v}" }.join(" ")}"
  end
end
