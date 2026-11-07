module RenderingTrial
  # 項目を文に分け、1文ずつ漢文化の部品（KanbunKa::KanbunTranslatorService）に通す。DBには書かない。
  # 結果は文ごとのハッシュ。原文（日本語）と骨格は持たない。parse_error は、理由の本文を除いて種類（例外のクラス名）だけを持つ。
  # 例外（MeCab の失敗、Ollama に繋がらない・時間切れなど）は、その文の error に例外のクラス名だけを記録して、続ける。
  class Runner
    def initialize(items, translator: KanbunKa::KanbunTranslatorService, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @items = items
      @translator = translator
      @clock = clock
    end

    # 日付ごとに処理し、日付が終わるたびにブロックへ (date, meta_for_dates, results_so_far) を渡す。
    # 戻り値は { dates: { 日付 => { items:, sentences: } }, results: [...], total_seconds: }。
    def call
      results = []
      dates = {}
      started = @clock.call
      @items.group_by(&:date).sort.each do |date, items|
        sentence_count = 0
        items.each do |item|
          SentenceSplitter.call(item.body).each_with_index do |sentence, i|
            sentence_count += 1
            results << translate(date, item, i + 1, sentence)
          end
        end
        dates[date] = { items: items.size, sentences: sentence_count }
        yield dates, results, @clock.call - started if block_given?
      end
      { dates:, results:, total_seconds: @clock.call - started }
    end

    # LLM を呼ばずに、日付ごとの項目数・文数だけを数える（ドライラン）。
    def self.plan(items)
      items.group_by(&:date).sort.to_h do |date, list|
        by_heading = list.group_by { |item| item.item_key.split(Diary::Rules::ITEM_KEY_SEPARATOR).first }.transform_values(&:size)
        [ date, { items: list.size, sentences: list.sum { |item| SentenceSplitter.call(item.body).size }, by_heading: } ]
      end
    end

    private

    def translate(date, item, number, sentence)
      base = { date:, segment_id: item.segment_id, item_key: item.item_key, sentence_no: number }
      started = @clock.call
      begin
        result = @translator.call(sentence)
      rescue StandardError => e
        return base.merge(error: e.class.name, seconds: @clock.call - started)
      end
      base.merge(
        fallback: result.fallback, retried: result.retried, hakubun_kind: hakubun_kind(result.hakubun),
        parse_error: result.parse_error && error_kind(result.parse_error), error: nil, seconds: @clock.call - started,
        hakubun: result.hakubun, kunten: result.kunten, kakikudashi: result.kakikudashi
      )
    end

    def hakubun_kind(hakubun)
      return "empty" if hakubun.to_s.strip.empty?

      hakubun.match?(KanbunKa::KanbunTranslatorService::HAKUBUN_PATTERN) ? "kanji_only" : "other"
    end

    # 「UnknownCharacters: …」の、コロンの前（例外のクラス名）だけ。理由の本文は捨てる。
    def error_kind(parse_error) = parse_error.to_s.split(":", 2).first.to_s.strip
  end
end
