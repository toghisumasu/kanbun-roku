require "test_helper"

class DiaryChunkTest < ActiveSupport::TestCase
  setup do
    first = Message.create!(source: "claude_ai", external_id: "c-1", session_id: "s-c", role: "human", body: "依頼", occurred_at: Time.zone.parse("2026-10-26 10:00"))
    last = Message.create!(source: "claude_ai", external_id: "c-2", session_id: "s-c", role: "assistant", body: "提案", occurred_at: Time.zone.parse("2026-10-26 10:01"))
    @segment = Segment.create!(session_id: "s-c", segment_date: Date.new(2026, 10, 26), first_message: first, last_message: last,
                               started_at: first.occurred_at, ended_at: last.occurred_at, start_reason: "first", end_reason: "gap")
  end

  def attributes(**overrides)
    { segment: @segment, chunk_index: 0, input_digest: "d1", model: "dummy", model_digest: "sha256:abc", prompt_version: "A-test" }.merge(overrides)
  end

  test "既定は pending。生の出力は text なので、JSON が崩れた出力もそのまま残せる" do
    chunk = DiaryChunk.create!(attributes(raw_output: "{\"決定\": [", error_kind: "invalid_json", status: "failed"))
    assert_equal "{\"決定\": [", chunk.reload.raw_output
    assert_equal "pending", DiaryChunk.create!(attributes(chunk_index: 1)).status
  end

  test "識別（座・塊・入力・モデル・プロンプトの版）が同じ記録は、1つだけ" do
    DiaryChunk.create!(attributes)
    assert_raises(ActiveRecord::RecordNotUnique) do
      ActiveRecord::Base.transaction(requires_new: true) { DiaryChunk.create!(attributes) }
    end
    assert DiaryChunk.create!(attributes(input_digest: "d2")).persisted?
    assert DiaryChunk.create!(attributes(prompt_version: "A-test-2")).persisted?
    assert DiaryChunk.create!(attributes(model: "other")).persisted?
  end

  test "status は決められた値だけ。scope で絞れる" do
    assert_not DiaryChunk.new(attributes(status: "done")).valid?
    DiaryChunk.create!(attributes(status: "succeeded"))
    DiaryChunk.create!(attributes(chunk_index: 1, status: "failed"))
    assert_equal 1, DiaryChunk.succeeded.count
    assert_equal 1, DiaryChunk.failed.count
  end

  test "モデルのダイジェスト・シード・所要時間・トークン数を記録できる" do
    chunk = DiaryChunk.create!(attributes(seed: 42, attempts: 2, done_reason: "stop", prompt_eval_count: 1500, eval_count: 600,
                                          total_duration_ms: 50_000, prompt_eval_duration_ms: 8_000, eval_duration_ms: 42_000))
    chunk.reload
    assert_equal "sha256:abc", chunk.model_digest
    assert_equal [ 42, 2, 1500, 600 ], [ chunk.seed, chunk.attempts, chunk.prompt_eval_count, chunk.eval_count ]
  end

  test "座を消そうとすると、塊の記録があれば止まる" do
    DiaryChunk.create!(attributes)
    assert_raises(ActiveRecord::DeleteRestrictionError) { @segment.destroy }
  end
end
