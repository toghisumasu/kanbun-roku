require "test_helper"

class SegmentChunkReportTest < ActiveSupport::TestCase
  Msg = Struct.new(:role, :body)

  test "区切りごとの塊数・省略した発言の数・削減率を数える（本文は含まない）" do
    small = SegmentChunker.call([ Msg.new("user", "こんにちは") ])
    split = SegmentChunker.call(Array.new(10) { Msg.new("user", "あ" * 300) }, limit: 500)
    huge = SegmentChunker.call([ Msg.new("user", "あ" * 5000) ], limit: 500)
    code = SegmentChunker.call([ Msg.new("assistant", "```\n#{"x\n" * 400}```") ])

    summary = SegmentChunkReport.summarize([ small, split, huge, code ])

    assert_equal 4, summary[:segments]
    assert_equal split.chunks.size, summary[:chunk_count_distribution].keys.max
    assert_equal 3, summary[:chunk_count_distribution][1]
    assert_equal 1, summary[:multi_chunk_segments]
    assert_equal 1, summary[:raw_oversized_messages]
    assert_equal 1, summary[:oversized_messages]
    assert_operator summary[:reduction_rate], :>, 0
    refute_match(/こんにちは/, SegmentChunkReport.text(summary))
  end

  test "区切りが無くても報告できる" do
    summary = SegmentChunkReport.summarize([])
    assert_equal 0, summary[:segments]
    assert_equal 0.0, summary[:reduction_rate]
    assert_kind_of String, SegmentChunkReport.text(summary)
  end
end
