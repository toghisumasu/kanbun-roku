# 1つの座について、A（人間の記録）のダイアリーを作る。単位は座。冪等で、中断しても、塊ごとの記録から続きを進める。
#
# - GPU が1つなので、同時に動かすのは1つだけ（limits_concurrency）。
# - 通信エラー・時間切れ（Ollama に繋がらない）は、間隔を広げて3回まで再試行する。
# - JSON の崩れ・打ち切りは、Generator が別の seed で1回だけ再試行する。それでも崩れた座は failed として記録し、
#   ジョブ自体は正常に終わる（他の座を止めない）。失敗した座は `bin/rails diary:report` で一覧し、
#   `bin/rails diary:retry_failed` で再投入する。
class GenerateDiaryJob < ApplicationJob
  queue_as :diary

  limits_concurrency to: 1, key: "ollama", duration: 1.hour

  retry_on Diary::OllamaClient::Unavailable, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(segment_id)
    result = Diary::Generator.call(Segment.find(segment_id))
    logger.info("[diary] segment=#{segment_id} status=#{result.status}#{" error=#{result.error}" if result.error}")
    result
  end
end
