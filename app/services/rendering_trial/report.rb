require "json"

module RenderingTrial
  # 試作の結果（JSON）を集計する。本文（白文・訓点・書き下し）は読まず、件数と秒数だけを数える。
  module Report
    Counts = Struct.new(:items, :sentences, :skeleton, :fallback, :kanji_only, :retried, :other_hakubun, :empty_hakubun, :parsed,
                        :parse_error, :parse_error_kinds, :errors, :error_kinds, :seconds, keyword_init: true)

    class << self
      def latest_file(dir = Rails.root.join("data")) = Dir[File.join(dir.to_s, "rendering-trial-*.json")].max

      # data: JSON.parse した結果（meta と results）。戻り値は { 日付 => Counts, "全体" => Counts }。
      def call(data)
        results = data.fetch("results")
        dates = data.fetch("meta").fetch("dates")
        table = dates.keys.sort.to_h { |date| [ date, count(results.select { |r| r["date"] == date }, dates.fetch(date)) ] }
        table["全体"] = count(results, { "items" => dates.values.sum { |d| d["items"] }, "sentences" => dates.values.sum { |d| d["sentences"] } })
        table
      end

      def lines(data)
        table = call(data)
        meta = data.fetch("meta")
        out = [ "漢文化の試作の集計（#{meta["generated_at"]} / モデル #{meta["model"]} / 日記 #{meta["prompt_version"]}・#{meta["rule_version"]}" \
                "#{" / 途中まで" unless meta["finished"]}）" ]
        table.each do |date, c|
          out << "" << date
          out << "  項目 #{c.items} / 文 #{c.sentences}（結果のある文 #{c.sentences - c.errors}、実行エラー #{c.errors}#{kinds(c.error_kinds)}）"
          out << "  骨格あり #{c.skeleton} / 骨格なし（fallback）#{c.fallback}"
          out << "  白文が漢字と句読点だけ #{c.kanji_only} / 再試行 #{c.retried} / 白文でない出力のまま #{c.other_hakubun}（空 #{c.empty_hakubun}）"
          out << "  訓点・書き下しあり #{c.parsed} / parse_error #{c.parse_error}#{kinds(c.parse_error_kinds)}"
          out << "  1文あたりの平均 #{format("%.2f", c.sentences.zero? ? 0 : c.seconds / c.sentences)} 秒 / 文の秒数の合計 #{format("%.1f", c.seconds)} 秒"
        end
        out << "" << "全体の所要時間 #{format("%.1f", meta["total_seconds"].to_f)} 秒（#{format("%.2f", meta["total_seconds"].to_f / 3600)} 時間）"
      end

      private

      def kinds(tally) = tally.empty? ? "" : "（#{tally.sort.map { |k, v| "#{k}=#{v}" }.join(" / ")}）"

      def count(rows, totals)
        ok = rows.reject { |r| r["error"] }
        Counts.new(
          items: totals["items"], sentences: totals["sentences"],
          skeleton: ok.count { |r| r["fallback"] == false }, fallback: ok.count { |r| r["fallback"] == true },
          kanji_only: ok.count { |r| r["hakubun_kind"] == "kanji_only" }, retried: ok.count { |r| r["retried"] == true },
          other_hakubun: ok.count { |r| r["hakubun_kind"] != "kanji_only" }, empty_hakubun: ok.count { |r| r["hakubun_kind"] == "empty" },
          parsed: ok.count { |r| r["parse_error"].nil? }, parse_error: ok.count { |r| r["parse_error"] },
          parse_error_kinds: ok.filter_map { |r| r["parse_error"] }.tally, errors: rows.count { |r| r["error"] },
          error_kinds: rows.filter_map { |r| r["error"] }.tally, seconds: rows.sum { |r| r["seconds"].to_f }
        )
      end
    end
  end
end
