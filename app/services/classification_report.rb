# 発言の分類・区切りの型・貼付省略の効果を数える（件数だけ。本文は出さない）。DBには触れない。
# segments: 区切りごとの発言の列（role / body / raw に答えるもの）の列。
class ClassificationReport
  def self.build(segments)
    new(segments).build
  end

  def initialize(segments)
    @segments = segments
  end

  def build
    user_classes = Hash.new(0)
    empty_user = Hash.new(0)
    empty_user_content_only = Hash.new(0)
    utterance_sizes = { "user" => [], "assistant" => [] }
    types = Hash.new(0)
    ratios = []
    tokens = { original: 0, without_paste: 0, with_paste: 0 }

    @segments.each do |messages|
      classes = messages.map { |m| [ m, MessageClassifier.classify(role: m.role, body: m.body, raw: m.raw) ] }
      users = classes.select { |m, _| m.role == "user" }
      users.each { |_, c| user_classes[c] += 1 }
      users.each do |m, _|
        next unless m.body.to_s.strip.empty?

        empty_user[MessageClassifier.media_label(m.raw)] += 1
        empty_user_content_only[MessageClassifier.media_label({ "content" => m.raw && m.raw["content"] })] += 1
      end
      classes.each { |m, c| utterance_sizes[m.role] << m.body.to_s.size if c == :utterance && utterance_sizes.key?(m.role) }

      user_only = users.map(&:last)
      types[SegmentTyper.call(user_only)] += 1
      ratios << SegmentTyper.paste_ratio(user_only)

      without = SegmentChunker.call(messages, trim_paste: false)
      with = SegmentChunker.call(messages)
      tokens[:original] += with.original_tokens
      tokens[:without_paste] += without.processed_tokens
      tokens[:with_paste] += with.processed_tokens
    end

    {
      segments: @segments.size,
      user_classes: user_classes,
      empty_user: empty_user,
      empty_user_content_only: empty_user_content_only,
      segment_types: types,
      paste_ratio: quantiles(ratios),
      tokens: tokens,
      utterance_chars: utterance_sizes.transform_values { |sizes| summary(sizes) }
        .merge("all" => summary(utterance_sizes.values.flatten))
    }
  end

  def self.text(r)
    t = r[:tokens]
    rate = ->(from, to) { from.zero? ? "0.0" : ((from - to).fdiv(from) * 100).round(1).to_s }
    <<~TEXT
      区切り: #{r[:segments]} 件
      role=user の発言の分類: #{MessageClassifier::CLASSES.map { |c| "#{c}=#{r[:user_classes][c]}" }.join(" / ")}
      本文が空の user 発言の内訳（content・files・attachments を見る）: #{label_counts(r[:empty_user])}
      　同（content のブロックだけで見た場合）: #{label_counts(r[:empty_user_content_only])}
      区切りの型（貼付の比率 #{SegmentTyper::WORK_PASTE_RATIO} 以上が work）: work=#{r[:segment_types][:work]} / talk=#{r[:segment_types][:talk]}
      　貼付の比率の分布（区切りごと）: #{r[:paste_ratio].map { |k, v| "#{k}=#{v.round(3)}" }.join(" ")}
      トークン（見積もり）: 前処理前 #{t[:original]} → 貼付省略なし #{t[:without_paste]} → 貼付省略あり #{t[:with_paste]}
      　貼付省略だけの削減率: #{rate.(t[:without_paste], t[:with_paste])}%（前処理前からの合計: #{rate.(t[:original], t[:with_paste])}%）
      utterance の文字数（最小 / 中央値 / 最大）:
      #{r[:utterance_chars].map { |k, s| "　#{k}: n=#{s[:n]} #{s[:min]} / #{s[:median]} / #{s[:max]}" }.join("\n")}
    TEXT
  end

  def self.label_counts(h) = %i[ image document both neither ].map { |k| "#{k}=#{h[k]}" }.join(" / ")

  private

  def summary(sizes)
    return { n: 0, min: 0, median: 0, max: 0 } if sizes.empty?

    sorted = sizes.sort
    mid = sorted.size / 2
    median = sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    { n: sorted.size, min: sorted.first, median: median, max: sorted.last }
  end

  def quantiles(values)
    return {} if values.empty?

    sorted = values.sort
    { "p25" => 0.25, "p50" => 0.5, "p75" => 0.75, "p90" => 0.9 }.transform_values { |q| sorted[((sorted.size - 1) * q).round] }
      .merge("max" => sorted.last)
  end
end
