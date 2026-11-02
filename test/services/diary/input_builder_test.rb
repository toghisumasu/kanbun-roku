require "test_helper"
require_relative "../../support/diary_helpers"

class Diary::InputBuilderTest < ActiveSupport::TestCase
  include DiaryHelpers

  def build(segment, **options) = Diary::InputBuilder.call(segment, detector: empty_detector, **options)

  test "入力は、人間の発言だけを、日本時間の時刻つきで時刻順に並べる（assistant の発言は入れない）" do
    segment = create_segment([ [ "user", "最初の依頼です", 0 ], [ "assistant", "返答はこちらです", 1 ], [ "user", "次の質問です", 65 ] ])
    built = build(segment)
    assert_equal 1, built.chunks.size
    assert_equal "[10:00] 最初の依頼です\n[11:05] 次の質問です", built.chunks.first.text
    assert_not_includes built.chunks.first.text, "返答"
  end

  test "端末出力（paste_text）は入れない。画像だけの発言は印にする" do
    terminal = "alice@host d % ls\n" + (1..5).map { |i| "out#{i}" }.join("\n")
    segment = create_segment([ [ "user", "依頼", 0 ], [ "user", terminal, 1 ], [ "user", "", 2 ] ],
                             raws: { 2 => { "files" => [ { "file_name" => "a.png" } ] } })
    text = build(segment).chunks.first.text
    assert_includes text, "[10:00] 依頼"
    assert_includes text, "[10:02] （画像）"
    assert_not_includes text, "alice@host"
  end

  test "Claude の文の貼り付けは、直前までの assistant 発言と照合して、一致した部分だけを印にする" do
    claude = "この設計では、区切りは原本から計算できる派生情報として扱い、メッセージ本体には一切書き込まない方針にします。"
    segment = create_segment([ [ "user", "質問", 0 ], [ "assistant", claude, 1 ], [ "user", "これを見て\n#{claude}\n続きの質問", 5 ] ])
    detector = ClaudePasteDetector.new(Message.where(role: "assistant").map { |m| Struct.new(:body, :occurred_at).new(m.body, m.occurred_at) })
    text = Diary::InputBuilder.call(segment, detector:).chunks.first.text
    assert_includes text, "（Claude文の貼り付け）"
    assert_includes text, "これを見て"
    assert_includes text, "続きの質問"
    assert_not_includes text, "メッセージ本体"
  end

  test "人間の発言（A が見た文）と、発言IDと時刻を、塊ごとに持つ" do
    segment = create_segment([ [ "user", "依頼A", 0 ], [ "assistant", "返答", 1 ], [ "user", "依頼B", 2 ] ])
    chunk = build(segment).chunks.first
    assert_equal [ "依頼A", "依頼B" ], chunk.human_messages.map(&:text)
    assert_equal Message.where(role: "user").order(:id).pluck(:id), chunk.human_messages.map(&:id)
    assert_equal "依頼A\n依頼B", chunk.own_text
  end

  test "上限を超えると、人間の発言の境界で塊に分かれる。各塊は上限以内" do
    specs = Array.new(12) { |i| [ "user", "漢字#{i}" * 40, i ] }
    built = build(create_segment(specs), limit: 800)
    assert_operator built.chunks.size, :>=, 2
    assert built.chunks.all? { |c| c.tokens <= 800 }
    assert_equal specs.size, built.human_messages.size
    assert_equal built.chunks.each_index.to_a, built.chunks.map(&:index)
  end

  test "ダイジェストは、入力が同じなら同じ、違えば違う" do
    a = build(create_segment([ [ "user", "同じ依頼", 0 ] ]))
    b = build(create_segment([ [ "user", "同じ依頼", 0 ] ]))
    c = build(create_segment([ [ "user", "違う依頼", 0 ] ]))
    assert_equal a.digest, b.digest
    assert_equal a.chunks.first.digest, b.chunks.first.digest
    assert_not_equal a.digest, c.digest
  end

  test "人間の発言がなければ、塊は空" do
    built = build(create_segment([ [ "assistant", "返答だけ", 0 ], [ "assistant", "続き", 1 ] ]))
    assert built.empty?
  end

  test "逆の発言者の文（先頭600文字まで）と、リンクの候補にする assistant メッセージ（会話全体）を持つ" do
    segment = create_segment([ [ "user", "依頼", 0 ], [ "assistant", "あ" * 700, 1 ] ], session: "s-x")
    built = build(segment)
    assert_equal "あ" * 600, built.other_text
    assert_equal Message.where(session_id: "s-x", role: "assistant").pluck(:id), built.assistant_messages.map(&:id)
  end

  test "座の型は、貼り付けの比率で work / talk" do
    terminal = "alice@host d % ls\n" + (1..5).map { |i| "out#{i}" }.join("\n")
    assert_equal :talk, build(create_segment([ [ "user", "ふつうの発言", 0 ], [ "user", "もうひとつ", 1 ] ])).type
    assert_equal :work, build(create_segment([ [ "user", terminal, 0 ], [ "user", "コメント", 1 ] ])).type
  end

  test "メッセージ（原本）は書き換えない" do
    segment = create_segment([ [ "user", "依頼", 0 ], [ "assistant", "返答", 1 ] ])
    before = Message.order(:id).pluck(:body, :raw)
    build(segment)
    assert_equal before, Message.order(:id).pluck(:body, :raw)
  end
end
