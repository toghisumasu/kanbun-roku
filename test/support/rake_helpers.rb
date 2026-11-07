# rake タスクをテストから呼ぶための補助。環境変数は呼んだあとで元に戻す。
# abort（SystemExit）で止まったタスクも、例外にせず、標準エラーと終了状態を返す。
require "rake"

module RakeHelpers
  RakeResult = Struct.new(:out, :err, :aborted, keyword_init: true)

  def run_rake(name, env = {})
    load_tasks_quietly unless Rake::Task.task_defined?(name)
    saved = env.keys.to_h { |key| [ key.to_s, ENV[key.to_s] ] }
    env.each { |key, value| ENV[key.to_s] = value }
    task = Rake::Task[name]
    task.reenable
    aborted = false
    out, err = capture_io do
      task.invoke
    rescue SystemExit
      aborted = true
    end
    RakeResult.new(out:, err:, aborted:)
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  private

  # rake ファイルは、読み込み直されると定数の再定義の警告を出す。テストの出力を汚さないよう、警告だけを抑える。
  def load_tasks_quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    Rails.application.load_tasks
  ensure
    $VERBOSE = verbose
  end
end
