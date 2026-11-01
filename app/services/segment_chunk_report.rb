# SegmentChunker の結果を区切りごとに集めて、dry-run の報告にする。DBには触れない。
# 本文は扱わない（数だけ）。
class SegmentChunkReport
  # results: SegmentChunker::Result の列（区切りごとに1つ）。
  def self.summarize(results)
    chunk_counts = results.map { |r| r.chunks.size }
    original = results.sum(&:original_tokens)
    processed = results.sum(&:processed_tokens)
    {
      segments: results.size,
      chunk_count_distribution: chunk_counts.tally.sort.to_h,
      multi_chunk_segments: chunk_counts.count { |n| n >= 2 },
      raw_oversized_messages: results.sum(&:raw_oversized),
      oversized_messages: results.sum(&:oversized),
      original_tokens: original,
      processed_tokens: processed,
      reduction_rate: original.zero? ? 0.0 : (original - processed).fdiv(original),
      max_chunk_tokens: results.flat_map { |r| r.chunks.map(&:tokens) }.max || 0
    }
  end

  def self.text(summary)
    <<~TEXT
      入力の上限: #{SegmentChunker::INPUT_LIMIT} トークン（assistant は先頭 #{SegmentChunker::ASSISTANT_HEAD_CHARS} 文字）
      区切り: #{summary[:segments]} 件
      塊数ごとの区切りの数: #{summary[:chunk_count_distribution].map { |n, c| "#{n}塊=#{c}" }.join(" / ")}
      2塊以上になる区切り: #{summary[:multi_chunk_segments]} 件
      単独で上限を超える発言: 前処理前 #{summary[:raw_oversized_messages]} 件 → 前処理後 #{summary[:oversized_messages]} 件（先頭と末尾を残して中略）
      トークン（見積もり）: #{summary[:original_tokens]} → #{summary[:processed_tokens]}（#{(summary[:reduction_rate] * 100).round(1)}% 減）
      最大の塊: #{summary[:max_chunk_tokens]} トークン
    TEXT
  end
end
