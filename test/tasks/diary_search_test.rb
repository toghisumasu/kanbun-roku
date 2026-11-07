require "test_helper"
require_relative "../support/diary_helpers"
require_relative "../support/rake_helpers"

# ダミーの会話・項目だけを使う。DBへの書き込みは、テストのトランザクション内だけ。
class DiarySearchTaskTest < ActiveSupport::TestCase
  include DiaryHelpers
  include RakeHelpers

  QUOTE_MARK = "QUOTE-ONLY-MARK"

  def item(heading, text, quote = QUOTE_MARK) = Diary::Item.new(heading:, text:, quote:, chunk_index: 0)

  # items: { 見出し => [Item] }。links: [[item_key, message_id, link_kind], ...]
  def make_entry(date, items, links = [])
    segment = create_segment([ [ "user", "ダミー発言", 0 ], [ "assistant", "ダミー返答", 1 ] ])
    segment.update!(segment_date: date)
    all = Diary::Rules::HEADINGS.to_h { |h| [ h, items.fetch(h, []) ] }
    specs = links.map { |key, message_id, kind| Diary::DecisionLinker::LinkSpec.new(item_key: key, message_id:, link_kind: kind) }
    [ segment, Diary::Assembler.call(segment:, model: "dummy-model", input_digest: "x", items: all, validation: {}, links: specs) ]
  end

  def search(env) = run_rake("diary:search", env)

  setup do
    @s1, @e1 = make_entry(Date.new(2026, 10, 1), { "決定" => [ item("決定", "サンプルAを採用する") ], "人間の考え" => [ item("人間の考え", "サンプルAは便利だと思う") ] })
    @s2, @e2 = make_entry(Date.new(2026, 11, 1), { "決定" => [ item("決定", "別の方針にする"), item("決定", "サンプルAの後で確認する") ] })
    @s3, @e3 = make_entry(Date.new(2026, 11, 5), { "未解決" => [ item("未解決", "ＳＡＭＰＬＥａの扱いは？") ] })
  end

  test "本文の部分一致で、座ID・日付・見出し・本文・リンクを1件ずつ出し、最後に件数を出す" do
    m1, m2 = Message.where(session_id: @s2.session_id).order(:id).to_a
    DiaryLink.create!(diary_entry: @e2, message: m1, item_key: "決定:1", link_kind: "source")
    DiaryLink.create!(diary_entry: @e2, message: m2, item_key: "決定:1", link_kind: "preceding_assistant_candidate")
    result = search(QUERY: "サンプルA", HEADING: "決定", FROM: "2026-11-01")
    assert_not result.aborted
    assert_includes result.out, "座 #{@s2.id} / 2026-11-01 / 決定 [決定:1]"
    assert_includes result.out, "本文: サンプルAの後で確認する"
    assert_includes result.out, "リンク: source #{m1.id} / 候補 #{m2.id}"
    assert_includes result.out, "該当 1 件 / 1 座"
    assert_not_includes result.out, "別の方針にする"
  end

  test "引用（原文の字面）は出さない。引用にだけある語では見つからない" do
    all = search(QUERY: "サンプルA")
    assert_not_includes all.out, QUOTE_MARK
    only_quote = search(QUERY: QUOTE_MARK)
    assert_equal 1, only_quote.out.lines.size # 件数の行だけ
    assert_includes only_quote.out, "該当 0 件 / 0 座"
  end

  test "見出しを絞らなければ、全見出しを探す。全角半角・大文字小文字の差を越える" do
    result = search(QUERY: "sampleA")
    assert_includes result.out, "該当 1 件 / 1 座"
    assert_includes result.out, "座 #{@s3.id} / 2026-11-05 / 未解決 [未解決:0]"
    assert_includes result.out, "リンク: source - / 候補 -"
    assert_includes search(QUERY: "ｓａｍｐｌｅ").out, "該当 1 件 / 1 座" # 半角の入力でも全角の本文に当たる
    assert_includes search(QUERY: "サンプルＡ").out, "該当 3 件 / 2 座" # 全角のＡは半角のAと同じ扱い（s1 の2件と s2 の1件）
  end

  test "FROM・TO は日付で絞る（両端を含む）" do
    assert_includes search(QUERY: "サンプルA", TO: "2026-10-31").out, "該当 2 件 / 1 座"
    assert_includes search(QUERY: "サンプルA", FROM: "2026-11-01", TO: "2026-11-01").out, "該当 1 件 / 1 座"
    assert_includes search(QUERY: "サンプルA", FROM: "2026-11-02").out, "該当 0 件 / 0 座"
  end

  test "結果は日付・座の順。DB は変更しない" do
    before = [ DiaryEntry.count, DiaryLink.count, Message.count ]
    out = search(QUERY: "サンプルA").out
    assert_operator out.index("座 #{@s1.id} /"), :<, out.index("座 #{@s2.id} /")
    assert_equal before, [ DiaryEntry.count, DiaryLink.count, Message.count ]
  end

  test "QUERY がない・HEADING が見出しにない・日付の形が違う・FROM が TO より後のときは、止まる" do
    [ {}, { QUERY: " " }, { QUERY: "a", HEADING: "感想" }, { QUERY: "a", FROM: "2026/11/01" }, { QUERY: "a", TO: "あした" },
      { QUERY: "a", FROM: "2026-11-05", TO: "2026-11-01" } ].each do |env|
      result = search(env)
      assert result.aborted, env.inspect
      assert_not_empty result.err, env.inspect
    end
  end
end
