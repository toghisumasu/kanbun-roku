require "test_helper"

class Diary::Prompts::ATest < ActiveSupport::TestCase
  # 指示文・スキーマ・設定を変えたら、PROMPT_VERSION を上げ、ここに新しい版の指紋を足す。
  EXPECTED_FINGERPRINTS = {
    "A-2026-11-02.1" => "7593b79e9742e16d"
  }.freeze

  A = Diary::Prompts::A

  test "指示文・スキーマ・設定を変えたら、PROMPT_VERSION を上げる" do
    expected = EXPECTED_FINGERPRINTS.fetch(A::PROMPT_VERSION) do
      flunk "PROMPT_VERSION（#{A::PROMPT_VERSION}）の指紋が、期待値の表にありません。新しい指紋は #{A.fingerprint} です。"
    end
    assert_equal expected, A.fingerprint,
      "指示文・スキーマ・設定が変わっています。PROMPT_VERSION を上げ、EXPECTED_FINGERPRINTS に新しい版と指紋（#{A.fingerprint}）を足してください。"
  end

  test "スキーマは、4つの見出しの配列で、件数は上限だけ（下限なし）" do
    assert_equal Diary::Rules::HEADINGS, A::SCHEMA[:required]
    Diary::Rules::HEADINGS.each do |heading|
      property = A::SCHEMA[:properties].fetch(heading)
      assert_equal "array", property[:type]
      assert_equal Diary::Rules::MAX_ITEMS.fetch(heading), property[:maxItems]
      assert_not property.key?(:minItems), "件数の下限は設けない"
      assert_equal %w[ 本文 引用 ], property[:items][:required]
    end
  end

  test "指示文に、印の意味・免除の文言・見出し・A: の規則が入っている" do
    text = A::INSTRUCTION
    assert_includes text, SegmentChunker::CLAUDE_PASTE_MARK
    SegmentChunker::MEDIA_MARKS.each_value { |mark| assert_includes text, mark }
    assert_includes text, SegmentChunker::EMPTY_MARK
    assert_includes text, Diary::Rules::EXEMPT_PHRASE
    Diary::Rules::HEADINGS.each { |heading| assert_includes text, "「#{heading}」" }
    assert_includes text, "「A:」の行"
    assert_includes text, "件数を合わせるために書かない"
    assert_includes text, "#{Diary::Rules::QUOTE_MAX_CHARS}文字以内"
  end

  test "指示文に Claude の発言を求める記述（B の内容）は入っていない" do
    assert_not_includes A::INSTRUCTION, "Claudeの提案・判断"
  end

  test "設定は num_ctx 16384・温度0.2・思考なしの前提（seed と keep_alive は含まない）" do
    assert_equal 16_384, A::OPTIONS[:num_ctx]
    assert_equal 0.2, A::OPTIONS[:temperature]
    assert_not A::OPTIONS.key?(:seed)
    assert_not A::OPTIONS.key?(:keep_alive)
  end

  test "指示文の見積もりトークン数は、入力の上限（INPUT_LIMIT）の計算に使われている" do
    tokens = SegmentChunker.estimate_tokens(A::INSTRUCTION)
    assert_operator tokens, :>, 500
    assert_equal SegmentChunker::INPUT_LIMIT, SegmentChunker.input_limit(A::INSTRUCTION)
  end
end
