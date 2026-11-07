# 漢文化の試作（第0弾）：日記の項目に、kanbun-ka から複製した漢文化の部品が通用するかを、件数で確かめる。
# DBには保存しない。画面に出すのは件数と秒数だけ。文ごとの結果（白文・訓点・書き下しを含む）は、
# gitignore 済みの data/rendering-trial-YYYYMMDD.json に書く（中身は画面に出さない）。
require "json"
require "net/http"
require "open3"

namespace :rendering_trial do
  def rendering_trial_dates
    list = ENV["DATES"].to_s.split(",").map(&:strip).reject(&:empty?)
    abort "DATES=2026-07-12,2026-02-08 のように、日付（YYYY-MM-DD）をコンマで区切って指定してください" if list.empty?

    list.uniq.map { |value| Date.iso8601(value) }.sort
  rescue Date::Error
    abort "DATES の日付は YYYY-MM-DD の形で指定してください"
  end

  # MeCab と Ollama のモデルがなければ、止まる（インストールや取得はしない）。
  def rendering_trial_preflight!
    _out, _err, status = Open3.capture3("which", "mecab")
    abort "mecab が見つかりません（インストールはしません）" unless status.success?

    model = KanbunKa::KanbunTranslatorService::OLLAMA_MODEL
    response = Net::HTTP.get_response(URI("http://localhost:11434/api/tags"))
    names = JSON.parse(response.body).fetch("models", []).map { |m| m["name"] }
    abort "Ollama にモデル #{model} がありません（取得はしません）" unless names.include?(model)
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, JSON::ParserError
    abort "Ollama（localhost:11434）に繋がりません"
  end

  def rendering_trial_write(path, meta, results)
    temp = "#{path}.partial"
    File.write(temp, JSON.generate({ "meta" => meta, "results" => results }))
    File.rename(temp, path)
  end

  desc "DATES=YYYY-MM-DD,… の日記の項目（決定・人間の考え。現行採用分）を文に分け、漢文化の部品に通す。" \
       "APPLY=1 のときだけ LLM を呼ぶ（既定はドライラン：日付ごとの項目数・文数だけ）。結果は data/rendering-trial-YYYYMMDD.json（FORCE=1 で上書き）"
  task run: :environment do
    dates = rendering_trial_dates
    selection = RenderingTrial::Targets.call(dates)
    plan = RenderingTrial::Runner.plan(selection.items)
    apply = ENV["APPLY"] == "1"

    puts "#{apply ? "実行" : "ドライラン（LLM は呼ばない）"}: 日記 #{Diary::Prompts::A::PROMPT_VERSION} / 規則 #{Diary::Rules::VERSION}、対象の日 #{dates.size}"
    dates.each do |date|
      row = plan[date.to_s]
      if row
        puts "  #{date}: 項目 #{row[:items]}（決定 #{row[:by_heading]["決定"].to_i} / 人間の考え #{row[:by_heading]["人間の考え"].to_i}）/ 文 #{row[:sentences]}"
      else
        puts "  #{date}: 項目 0（該当する日記がない）"
      end
    end
    puts "合計: 項目 #{selection.items.size} / 文 #{plan.values.sum { |row| row[:sentences] }}（本文が空で除いた項目 #{selection.skipped_empty}）"
    next unless apply

    rendering_trial_preflight!
    path = Rails.root.join("data", "rendering-trial-#{Time.current.in_time_zone("Asia/Tokyo").strftime("%Y%m%d")}.json").to_s
    abort "#{path} がすでにあります（上書きするなら FORCE=1）" if File.exist?(path) && ENV["FORCE"] != "1"
    FileUtils.mkdir_p(File.dirname(path))

    meta = lambda do |dates_meta, seconds, finished|
      { "generated_at" => Time.current.iso8601, "model" => KanbunKa::KanbunTranslatorService::OLLAMA_MODEL,
        "prompt_version" => Diary::Prompts::A::PROMPT_VERSION, "rule_version" => Diary::Rules::VERSION,
        "dates" => dates_meta.transform_values { |v| v.transform_keys(&:to_s) }, "total_seconds" => seconds, "finished" => finished }
    end
    outcome = RenderingTrial::Runner.new(selection.items).call do |dates_meta, results, seconds|
      rendering_trial_write(path, meta.call(dates_meta, seconds, false), results.map(&:stringify_keys))
      puts "  #{dates_meta.keys.last}: 完了（文 #{results.size} 件まで、経過 #{seconds.round} 秒）"
    end
    rendering_trial_write(path, meta.call(outcome[:dates], outcome[:total_seconds], true), outcome[:results].map(&:stringify_keys))
    puts "結果を #{path} に書きました（中身は画面に出していません）。集計: bin/rails rendering_trial:report"
  end

  desc "直近の data/rendering-trial-*.json（FILE= で指定もできる）から、件数と秒数だけを集計して画面に出す。本文は出さない"
  task report: :environment do
    path = ENV["FILE"].presence || RenderingTrial::Report.latest_file
    abort "data/rendering-trial-*.json がありません" unless path && File.exist?(path)

    puts RenderingTrial::Report.lines(JSON.parse(File.read(path)))
  end
end
