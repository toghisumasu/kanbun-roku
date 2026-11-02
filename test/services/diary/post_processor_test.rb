require "test_helper"

# ダミーの文だけを使う。DBには触れない。
class Diary::PostProcessorTest < ActiveSupport::TestCase
  P = Diary::PostProcessor

  def item(heading, text, quote = "", chunk_index: nil) = Diary::Item.new(heading:, text:, quote:, chunk_index:)

  def chunk(**by_heading) = by_heading.transform_keys { |k| heading_name(k) }

  HEADING_NAMES = { request: "人間の依頼・共有", decision: "決定", thought: "人間の考え", open: "未解決" }.freeze
  def heading_name(key) = HEADING_NAMES.fetch(key)

  def texts(result, key) = result.items[heading_name(key)].map(&:text)

  # 同じ話題を言い換えた、似ている本文の組（Dice 係数が 0.5 以上になる）。
  SIMILAR_A = "データベースの設計を見直す方針を決めた"
  SIMILAR_B = "データベースの設計を見直す方針にする"
  OTHER_TOPIC = "来週の旅行の予定について考えている"

  test "似ている項目は、優先度の低い見出し側を落とす（決定 > 人間の考え > 未解決 > 依頼・共有）" do
    assert_operator P.dice(Diary::QuoteVerifier.normalize(SIMILAR_A), Diary::QuoteVerifier.normalize(SIMILAR_B)), :>=, 0.5
    result = P.call([ chunk(decision: [ item("決定", SIMILAR_A) ], thought: [ item("人間の考え", SIMILAR_B) ]) ])
    assert_equal [ SIMILAR_A ], texts(result, :decision)
    assert_equal [], texts(result, :thought)
    assert_equal 1, result.dropped.size
    assert_equal [ SIMILAR_B ], result.dropped.map { |dropped, _| dropped.text }
    assert_equal [ SIMILAR_A ], result.dropped.map { |_, winner| winner.text }
  end

  test "優先度の順：決定 > 人間の考え > 未解決 > 依頼・共有" do
    pairs = [ %i[ decision thought ], %i[ decision open ], %i[ decision request ], %i[ thought open ], %i[ thought request ], %i[ open request ] ]
    pairs.each do |high, low|
      result = P.call([ chunk(high => [ item(heading_name(high), SIMILAR_A) ], low => [ item(heading_name(low), SIMILAR_B) ]) ])
      assert_equal 1, result.items[heading_name(high)].size, "#{high} が残る"
      assert_equal 0, result.items[heading_name(low)].size, "#{low} が落ちる"
    end
  end

  test "似ていない項目は落とさない。同じ見出しの中では、似ていても落とさない" do
    result = P.call([ chunk(decision: [ item("決定", SIMILAR_A) ], thought: [ item("人間の考え", OTHER_TOPIC) ]) ])
    assert_equal 0, result.dropped.size
    same = P.call([ chunk(thought: [ item("人間の考え", SIMILAR_A), item("人間の考え", SIMILAR_B) ]) ])
    assert_equal 2, same.items["人間の考え"].size
    assert_equal 0, same.dropped.size
  end

  test "Dice 係数の閾値は 0.5 以上（ちょうど0.5は重複）" do
    # 文字2-gram: "あいうえ" -> {あい, いう, うえ}、"あいうお" -> {あい, いう, うお}。共通2、各3 -> 2*2/6 = 0.667
    assert_in_delta 0.667, P.dice("あいうえ", "あいうお"), 0.001
    # 共通1、各2 -> 2*1/4 = 0.5 ちょうど
    assert_in_delta 0.5, P.dice("あいう", "あいえ"), 0.001
    result = P.call([ chunk(decision: [ item("決定", "あいう") ], thought: [ item("人間の考え", "あいえ") ]) ])
    assert_equal 1, result.dropped.size
    below = P.call([ chunk(decision: [ item("決定", "あいう") ], thought: [ item("人間の考え", "あかえ") ]) ])
    assert_equal 0, below.dropped.size
  end

  test "1文字以下の本文は、重複とみなさない" do
    assert_equal 0.0, P.dice("あ", "あ")
    assert_equal 0.0, P.dice("", "あい")
  end

  test "正規化（句読点・全角半角・空白）の差を越えて、重複を判定する" do
    a = item("決定", "データベースの 設計を、見直す方針に決めた。")
    b = item("人間の考え", "データベースの設計を見直す方針に決めた")
    assert_equal 1, P.call([ chunk(decision: [ a ], thought: [ b ]) ]).dropped.size
  end

  test "複数の塊は、塊の順・出力の順に連結する。塊をまたいでも重複を落とす" do
    chunks = [
      chunk(request: [ item("人間の依頼・共有", "最初の依頼", "", chunk_index: 0) ], decision: [ item("決定", SIMILAR_A, "", chunk_index: 0) ]),
      chunk(request: [ item("人間の依頼・共有", "二番目の依頼", "", chunk_index: 1), item("人間の依頼・共有", SIMILAR_B, "", chunk_index: 1) ])
    ]
    result = P.call(chunks)
    assert_equal [ "最初の依頼", "二番目の依頼" ], texts(result, :request)
    assert_equal [ 0, 1 ], result.items["人間の依頼・共有"].map(&:chunk_index)
    assert_equal [ SIMILAR_B ], result.dropped.map { |dropped, _| dropped.text }
  end

  test "再分類（c）：決定の引用が ください・お願いします・ますか で終わる項目は、依頼・共有へ移す" do
    %w[ これを確認してください。 確認をお願いします 動きますか？ 動きますか ].each do |quote|
      result = P.call([ chunk(decision: [ item("決定", "移る項目", quote) ]) ])
      assert_equal 0, result.items["決定"].size, quote
      assert_equal [ "人間の依頼・共有" ], result.items["人間の依頼・共有"].map(&:heading), quote
      assert_equal 1, result.moved.size
      assert_equal "決定", result.moved.first.first.heading
      assert_equal "人間の依頼・共有", result.moved.first.last.heading
    end
  end

  test "再分類（c）：語尾が違う決定、決定以外の見出し、引用が空の決定は、移さない" do
    stay = P.call([ chunk(decision: [ item("決定", "残る", "この方針にします"), item("決定", "引用なし", "") ]) ])
    assert_equal 2, stay.items["決定"].size
    assert_equal [], stay.moved
    other = P.call([ chunk(thought: [ item("人間の考え", "考え", "確認してください") ]) ])
    assert_equal 1, other.items["人間の考え"].size
    assert_equal [], other.moved
  end

  test "再分類してから重複を落とす（移した項目も、決定との重複で落ちうる）" do
    result = P.call([ chunk(decision: [ item("決定", SIMILAR_A, "この方針にします"), item("決定", SIMILAR_B, "確認してください") ]) ])
    assert_equal [ SIMILAR_A ], texts(result, :decision)
    assert_equal [], texts(result, :request) # 移した SIMILAR_B は、決定の SIMILAR_A と似ているので落ちる
    assert_equal 1, result.moved.size
    assert_equal 1, result.dropped.size
  end

  test "残した項目は、元の順序を保つ" do
    result = P.call([ chunk(thought: [ item("人間の考え", "一つ目の考え"), item("人間の考え", SIMILAR_B), item("人間の考え", "三つ目の別の考え") ],
                            decision: [ item("決定", SIMILAR_A) ]) ])
    assert_equal [ "一つ目の考え", "三つ目の別の考え" ], texts(result, :thought)
  end

  test "全見出しのキーを持つ。入力が空でも動き、counts を返す" do
    result = P.call([ {} ])
    assert_equal Diary::Rules::HEADINGS, result.items.keys
    assert_equal({ "人間の依頼・共有" => 0, "決定" => 0, "人間の考え" => 0, "未解決" => 0 }, result.counts)
    assert_equal 0, P.call([]).items.values.sum(&:size)
  end

  test "入力の項目は書き換えない（冪等）" do
    first = chunk(decision: [ item("決定", SIMILAR_A) ], thought: [ item("人間の考え", SIMILAR_B) ])
    snapshot = Marshal.load(Marshal.dump(first))
    once = P.call([ first ])
    assert_equal snapshot, first
    twice = P.call([ once.items ])
    assert_equal once.items, twice.items
    assert_equal 0, twice.dropped.size
  end
end
