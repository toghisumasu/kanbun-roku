require "test_helper"
require_relative "../support/diary_helpers"
require_relative "../support/rake_helpers"

# ダミーの会話だけを使う。読み取りのみのタスクなので、DBは変更しない。
class DiarySourceTaskTest < ActiveSupport::TestCase
  include DiaryHelpers
  include RakeHelpers

  def source(env) = run_rake("diary:source", env)

  setup do
    # user と assistant が交互に9件。本文は「発言0」〜「発言8」。
    specs = (0..8).map { |i| [ i.even? ? "user" : "assistant", "発言#{i}", i ] }
    @segment = create_segment(specs)
    @messages = Message.where(session_id: @segment.session_id).order(:id).to_a
    @other = create_segment([ [ "user", "別の会話の発言", 0 ] ])
  end

  test "指定した発言を ▶ で示し、前後 CONTEXT 件を、発言者・時刻（日本時間）つきで時刻順に出す" do
    target = @messages[4]
    result = source(ID: target.id.to_s, CONTEXT: "2")
    assert_not result.aborted
    lines = result.out.lines.map(&:chomp)
    assert_equal "メッセージ #{target.id} / 会話 #{@segment.session_id} / 座 #{@segment.id} / 前後 2 件（会話内の 5 / 9 番目）", lines.first
    assert_includes result.out, "▶ [人間] 2026-11-01 10:04:00 (id #{target.id})"
    assert_includes result.out, "  [Claude] 2026-11-01 10:03:00 (id #{@messages[3].id})"
    assert_equal %w[ 発言2 発言3 発言4 発言5 発言6 ], result.out.scan(/発言\d/)
    assert_not_includes result.out, "別の会話の発言"
  end

  test "CONTEXT の既定は5件。会話の端では、ある分だけを出す" do
    middle = source(ID: @messages[4].id.to_s)
    assert_equal (0..8).map { |i| "発言#{i}" }, middle.out.scan(/発言\d/)
    first = source(ID: @messages[0].id.to_s, CONTEXT: "1")
    assert_equal %w[ 発言0 発言1 ], first.out.scan(/発言\d/)
    assert_includes first.out, "（会話内の 1 / 9 番目）"
    last = source(ID: @messages[8].id.to_s, CONTEXT: "0")
    assert_equal %w[ 発言8 ], last.out.scan(/発言\d/)
  end

  test "本文が空の発言は「(本文なし)」と出す。座に入らない発言でも、座は - と出す" do
    session = "s-empty-#{SecureRandom.hex(4)}"
    empty = Message.create!(source: "claude_ai", external_id: "#{session}-0", session_id: session, role: "user", body: "",
                            occurred_at: DiaryHelpers::BASE_TIME, raw: {})
    result = source(ID: empty.id.to_s)
    assert_includes result.out, "(本文なし)"
    assert_includes result.out, "座 - /"
  end

  test "ID がない・数字でない・存在しない、CONTEXT が負や数字でないときは、止まる" do
    [ {}, { ID: "abc" }, { ID: "0" }, { ID: "-1" }, { ID: @messages[0].id.to_s, CONTEXT: "-1" }, { ID: @messages[0].id.to_s, CONTEXT: "x" } ].each do |env|
      result = source(env)
      assert result.aborted, env.inspect
      assert_not_empty result.err, env.inspect
    end
  end

  test "DB は変更しない" do
    before = [ Message.count, DiaryEntry.count, DiaryLink.count ]
    source(ID: @messages[2].id.to_s)
    assert_equal before, [ Message.count, DiaryEntry.count, DiaryLink.count ]
  end
end
