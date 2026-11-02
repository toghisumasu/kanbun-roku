require "test_helper"

class Diary::RulesTest < ActiveSupport::TestCase
  # 規則の定数（前処理の定数を含む）を変えたら、VERSION を上げ、ここに新しい版の指紋を足す。
  # 定数を変えただけで VERSION を上げていないと、このテストが落ちる。VERSION だけ上げて指紋を足さなくても落ちる。
  EXPECTED_FINGERPRINTS = {
    "2026-11-02.1" => "15bfbafda924af9b",
    "2026-11-02.2" => "2a46eda5af81a745" # 入力の上限を A の指示文と num_predict で計算し直した。A の塊を人間の発言だけで分ける
  }.freeze

  test "規則の定数を変えたら、VERSION を上げる（指紋が版ごとの期待値と一致する）" do
    expected = EXPECTED_FINGERPRINTS.fetch(Diary::Rules::VERSION) do
      flunk "Rules::VERSION（#{Diary::Rules::VERSION}）の指紋が、期待値の表にありません。新しい指紋は #{Diary::Rules.fingerprint} です。"
    end
    assert_equal expected, Diary::Rules.fingerprint,
      "規則の定数が変わっています。VERSION を上げ、EXPECTED_FINGERPRINTS に新しい版と指紋（#{Diary::Rules.fingerprint}）を足してください。"
  end

  test "指紋は、キーの順に依存しない" do
    reversed = Diary::Rules.snapshot.to_a.reverse.to_h.transform_values { |v| v.is_a?(Hash) ? v.to_a.reverse.to_h : v }
    assert_not_equal Diary::Rules.snapshot.keys, reversed.keys
    assert_equal Diary::Rules.fingerprint, Diary::Rules.fingerprint(reversed)
  end

  test "snapshot は、規則・検出器・分類器・チャンカーの定数を含む" do
    snapshot = Diary::Rules.snapshot
    assert_equal %w[ chunker classifier detector diary ], snapshot.keys.sort
    assert_equal ClaudePasteDetector::MIN_CHARS, snapshot["detector"]["min_chars"]
    assert_equal MessageClassifier::PASTE_MIN_LINES, snapshot["classifier"]["paste_min_lines"]
    assert_equal SegmentChunker::ASSISTANT_HEAD_CHARS, snapshot["chunker"]["assistant_head_chars"]
    assert_equal SegmentChunker::INPUT_LIMIT, snapshot["chunker"]["input_limit"]
    assert_equal Diary::Rules::DICE_THRESHOLD, snapshot["diary"]["dice_threshold"]
  end

  test "snapshot の値が変わると、指紋が変わる" do
    changed = Diary::Rules.snapshot.deep_dup
    changed["detector"]["min_chars"] += 1
    assert_not_equal Diary::Rules.fingerprint, Diary::Rules.fingerprint(changed)
    changed_diary = Diary::Rules.snapshot.deep_dup
    changed_diary["diary"]["dice_threshold"] = 0.6
    assert_not_equal Diary::Rules.fingerprint, Diary::Rules.fingerprint(changed_diary)
  end

  test "見出し・優先度・件数の上限の整合" do
    assert_equal Diary::Rules::HEADINGS.sort, Diary::Rules::PRIORITY.sort
    assert_equal Diary::Rules::HEADINGS.sort, Diary::Rules::MAX_ITEMS.keys.sort
    assert_equal "決定", Diary::Rules::PRIORITY.first
    assert_equal "人間の依頼・共有", Diary::Rules::PRIORITY.last
    assert_includes Diary::Rules::HEADINGS, Diary::Rules::RECLASSIFY_TO
  end
end
