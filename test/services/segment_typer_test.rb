require "test_helper"

class SegmentTyperTest < ActiveSupport::TestCase
  test "貼付の比率が閾値以上なら work、未満なら talk" do
    ratio = SegmentTyper::WORK_PASTE_RATIO
    assert_equal :work, SegmentTyper.call(%i[ paste_text paste_media utterance ])
    assert_equal :talk, SegmentTyper.call(%i[ utterance utterance utterance utterance ])
    assert_equal :work, SegmentTyper.call(%i[ paste_text utterance ], threshold: 0.5)
    assert_equal :talk, SegmentTyper.call(%i[ paste_text utterance utterance ], threshold: 0.5)
    assert_in_delta 1.0 / 3, SegmentTyper.paste_ratio(%i[ paste_text utterance utterance ])
    assert_operator ratio, :>, 0
  end

  test "user の発言がない区切りは talk" do
    assert_equal 0.0, SegmentTyper.paste_ratio([])
    assert_equal :talk, SegmentTyper.call([])
  end
end
