require "test_helper"
require_relative "../support/diary_helpers"

class GenerateDiaryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DiaryHelpers

  setup do
    @original_factory = Diary::Generator.instance_variable_get(:@client_factory)
    Diary::DetectorCache.reset!
  end

  teardown do
    Diary::Generator.client_factory = @original_factory
    Diary::DetectorCache.reset!
  end

  def segment
    @segment ||= create_segment([ [ "user", "データベースの設計を見直したい。", 0 ], [ "assistant", "返答", 1 ], [ "user", "次の作業は来週にします。", 2 ] ])
  end

  def good_output = a_json("決定" => [ [ "来週にすると決めた", "次の作業は来週にします" ] ])

  test "専用キュー diary で、同時に動かすのは1つだけ（Ollama 用）" do
    assert_equal "diary", GenerateDiaryJob.new.queue_name
    assert_equal 1, GenerateDiaryJob.concurrency_limit
  end

  test "座を渡すと、ダイアリーを作る" do
    client = FakeClient.new(response(good_output))
    Diary::Generator.client_factory = -> { client }
    result = GenerateDiaryJob.perform_now(segment.id)
    assert_equal :generated, result.status
    assert_equal 1, DiaryEntry.where(segment_id: segment.id).count
  end

  test "冪等：同じ座を2回流しても、LLM の呼び出しは1回" do
    client = FakeClient.new(response(good_output))
    Diary::Generator.client_factory = -> { client }
    GenerateDiaryJob.perform_now(segment.id)
    assert_equal :skipped_up_to_date, GenerateDiaryJob.perform_now(segment.id).status
    assert_equal 1, client.calls.size
  end

  test "JSON が崩れた座は failed として記録し、ジョブは正常に終わる（他の座を止めない。再試行のジョブも積まない）" do
    client = FakeClient.new(response("壊れた"), response("まだ壊れた"))
    Diary::Generator.client_factory = -> { client }
    assert_no_enqueued_jobs do
      assert_equal :failed, GenerateDiaryJob.perform_now(segment.id).status
    end
    assert_equal "failed", DiaryChunk.find_by!(segment_id: segment.id).status
    assert_equal 0, DiaryEntry.count
  end

  test "通信エラー（Ollama に繋がらない）は、再試行のジョブを積む" do
    client = FakeClient.new(Diary::OllamaClient::Unavailable.new("接続できません"))
    Diary::Generator.client_factory = -> { client }
    assert_enqueued_jobs 1, only: GenerateDiaryJob do
      GenerateDiaryJob.perform_now(segment.id)
    end
    assert_equal 0, DiaryEntry.count
  end

  test "存在しない座は、捨てる（再試行しない）" do
    Diary::Generator.client_factory = -> { FakeClient.new(response(good_output)) }
    assert_no_enqueued_jobs { GenerateDiaryJob.perform_now(0) }
  end

  test "失敗した座は、あとで同じジョブで再実行できる（別の seed で作り直す）" do
    Diary::Generator.client_factory = -> { FakeClient.new(response("壊れた")) }
    GenerateDiaryJob.perform_now(segment.id)
    Diary::Generator.client_factory = -> { FakeClient.new(response(good_output)) }
    assert_equal :generated, GenerateDiaryJob.perform_now(segment.id).status
    assert_equal "succeeded", DiaryChunk.find_by!(segment_id: segment.id).status
  end

  test "chunks_only: true なら、塊の記録だけを作り、ダイアリーは作らない" do
    client = FakeClient.new(response(good_output))
    Diary::Generator.client_factory = -> { client }
    assert_equal :chunks_recorded, GenerateDiaryJob.perform_now(segment.id, chunks_only: true).status
    assert_equal 0, DiaryEntry.where(segment_id: segment.id).count
    assert_equal 1, DiaryChunk.where(segment_id: segment.id, status: "succeeded").count
  end
end
