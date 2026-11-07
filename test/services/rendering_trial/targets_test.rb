require "test_helper"
require_relative "../../support/diary_helpers"

# ダミーの項目だけを使う。DBの書き込みは、テストのトランザクション内だけ。
class RenderingTrial::TargetsTest < ActiveSupport::TestCase
  include DiaryHelpers

  def item(heading, text) = Diary::Item.new(heading:, text:, quote: "", chunk_index: 0)

  def make_entry(date, items, prompt_version: Diary::Prompts::A::PROMPT_VERSION, rule_version: Diary::Rules::VERSION)
    segment = create_segment([ [ "user", "ダミー", 0 ], [ "assistant", "返答", 1 ] ])
    segment.update!(segment_date: date)
    all = Diary::Rules::HEADINGS.to_h { |h| [ h, items.fetch(h, []) ] }
    entry = Diary::Assembler.call(segment:, model: "dummy-model", input_digest: "x", items: all, validation: {}, links: [])
    entry.update!(prompt_version:, rule_version:)
    [ segment, entry ]
  end

  test "指定した日の「決定」「人間の考え」だけを、日付・座・見出し・位置の順に取る。依頼・共有と未解決は取らない" do
    s1, = make_entry(Date.new(2026, 11, 1), { "決定" => [ item("決定", "甲を採用する") ], "人間の考え" => [ item("人間の考え", "乙は有用だ") ],
                                              "未解決" => [ item("未解決", "丙はどうか？") ], "人間の依頼・共有" => [ item("人間の依頼・共有", "丁を依頼した") ] })
    s2, = make_entry(Date.new(2026, 11, 2), { "決定" => [ item("決定", "戊を決めた"), item("決定", "己も決めた") ] })
    selection = RenderingTrial::Targets.call([ Date.new(2026, 11, 2), Date.new(2026, 11, 1) ])
    assert_equal [ [ "2026-11-01", s1.id, "決定:0" ], [ "2026-11-01", s1.id, "人間の考え:0" ], [ "2026-11-02", s2.id, "決定:0" ], [ "2026-11-02", s2.id, "決定:1" ] ],
      selection.items.map { |i| [ i.date, i.segment_id, i.item_key ] }
    assert_equal [ "甲を採用する", "乙は有用だ", "戊を決めた", "己も決めた" ], selection.items.map(&:body)
    assert_equal 0, selection.skipped_empty
  end

  test "指定していない日、現行の版でない日記は取らない" do
    make_entry(Date.new(2026, 11, 1), { "決定" => [ item("決定", "対象外の日") ] })
    make_entry(Date.new(2026, 11, 3), { "決定" => [ item("決定", "古い規則の版") ] }, rule_version: "old")
    make_entry(Date.new(2026, 11, 3), { "決定" => [ item("決定", "古いプロンプトの版") ] }, prompt_version: "A-old")
    assert_empty RenderingTrial::Targets.call([ Date.new(2026, 11, 3) ]).items
  end

  test "本文が空（空白だけを含む）の項目は除き、除いた数を数える" do
    make_entry(Date.new(2026, 11, 1), { "決定" => [ item("決定", "  "), item("決定", "本文あり"), item("決定", "") ] })
    selection = RenderingTrial::Targets.call([ Date.new(2026, 11, 1) ])
    assert_equal [ "本文あり" ], selection.items.map(&:body)
    assert_equal [ "決定:1" ], selection.items.map(&:item_key)
    assert_equal 2, selection.skipped_empty
  end

  test "DB は変更しない" do
    make_entry(Date.new(2026, 11, 1), { "決定" => [ item("決定", "ダミー") ] })
    before = [ DiaryEntry.count, DiaryLink.count, DiaryChunk.count, Message.count ]
    RenderingTrial::Targets.call([ Date.new(2026, 11, 1) ])
    assert_equal before, [ DiaryEntry.count, DiaryLink.count, DiaryChunk.count, Message.count ]
  end
end
