require "test_helper"

# ダミーの発言だけを使う。DBには触れない。
class Diary::DecisionLinkerTest < ActiveSupport::TestCase
  L = Diary::DecisionLinker

  def at(minute) = Time.utc(2026, 11, 1, 10) + (minute * 60)
  def human(id, minute, text) = L::HumanMessage.new(id:, occurred_at: at(minute), text:)
  def assistant(id, minute) = L::AssistantMessage.new(id:, occurred_at: at(minute))
  def item(heading, quote) = Diary::Item.new(heading:, text: "本文", quote:)

  def call(items_by_heading, humans, assistants = [])
    L.call(items_by_heading, human_messages: humans, assistant_messages: assistants)
  end

  def links(result) = result.links.map { |l| [ l.item_key, l.message_id, l.link_kind ] }

  test "item_key は「見出し:位置」" do
    assert_equal "決定:2", L.item_key("決定", 2)
    assert_equal "人間の考え:0", L.item_key("人間の考え", 0)
  end

  test "引用が人間の発言に含まれれば、その発言への source リンクを付ける" do
    humans = [ human(1, 0, "最初の依頼です"), human(2, 5, "次の作業は来週にします") ]
    result = call({ "人間の考え" => [ item("人間の考え", "次の作業は来週にします") ] }, humans)
    assert_equal [ [ "人間の考え:0", 2, "source" ] ], links(result)
    assert_equal [], result.unmatched
  end

  test "引用が複数の発言に一致するときは、時刻が最も早い発言を採る。同時刻なら id が小さい方" do
    humans = [ human(7, 10, "この方針にします"), human(3, 5, "この方針にします。確認した"), human(9, 5, "この方針にします") ]
    result = call({ "決定" => [ item("決定", "この方針にします") ] }, humans)
    assert_equal [ [ "決定:0", 3, "source" ] ], links(result)
  end

  test "時刻の順は、渡された配列の順に依存しない" do
    humans = [ human(1, 9, "同じ文です。同じ文です"), human(2, 1, "同じ文です") ]
    forward = call({ "決定" => [ item("決定", "同じ文です") ] }, humans)
    backward = call({ "決定" => [ item("決定", "同じ文です") ] }, humans.reverse)
    assert_equal links(forward), links(backward)
    assert_equal 2, forward.links.first.message_id
  end

  test "決定の項目には、source の発言より前の、最も後ろの assistant メッセージを、候補として結ぶ" do
    humans = [ human(10, 6, "この方針にします") ]
    assistants = [ assistant(1, 0), assistant(2, 4), assistant(3, 5), assistant(4, 7) ]
    result = call({ "決定" => [ item("決定", "この方針にします") ] }, humans, assistants)
    assert_equal [ [ "決定:0", 10, "source" ], [ "決定:0", 3, "preceding_assistant_candidate" ] ], links(result)
  end

  test "候補は、同時刻の assistant メッセージを使わない（厳密に前）。ひとつもなければ候補は付けない" do
    humans = [ human(10, 5, "この方針にします") ]
    same_time = call({ "決定" => [ item("決定", "この方針にします") ] }, humans, [ assistant(1, 5), assistant(2, 6) ])
    assert_equal [ [ "決定:0", 10, "source" ] ], links(same_time)
    none = call({ "決定" => [ item("決定", "この方針にします") ] }, humans, [])
    assert_equal [ [ "決定:0", 10, "source" ] ], links(none)
  end

  test "候補リンクは決定の項目だけ。ほかの見出しには source だけ" do
    humans = [ human(10, 6, "気になる点があります。この方針にします") ]
    assistants = [ assistant(1, 0) ]
    result = call({ "決定" => [ item("決定", "この方針にします") ], "人間の考え" => [ item("人間の考え", "気になる点があります") ] }, humans, assistants)
    assert_equal [ [ "決定:0", 10, "source" ], [ "決定:0", 1, "preceding_assistant_candidate" ], [ "人間の考え:0", 10, "source" ] ], links(result)
  end

  test "候補は同じ会話の assistant を渡したものから選ぶ（座の前の発言でもよい）" do
    humans = [ human(10, 6, "この方針にします") ]
    result = call({ "決定" => [ item("決定", "この方針にします") ] }, humans, [ assistant(1, -30) ])
    assert_equal "preceding_assistant_candidate", result.links.last.link_kind
  end

  test "一致する発言がない引用は、リンクを付けず、unmatched に item_key を残す。候補も付けない" do
    humans = [ human(1, 0, "最初の依頼です") ]
    result = call({ "決定" => [ item("決定", "どこにもない文字列の引用です") ] }, humans, [ assistant(5, -1) ])
    assert_equal [], result.links
    assert_equal [ "決定:0" ], result.unmatched
  end

  test "引用が空の項目は、リンクを付けず、unmatched にも入れない" do
    result = call({ "人間の依頼・共有" => [ item("人間の依頼・共有", "") ] }, [ human(1, 0, "なにか") ])
    assert_equal [], result.links
    assert_equal [], result.unmatched
  end

  test "item_key は、後処理後の見出しごとの位置" do
    humans = [ human(1, 0, "一つ目の引用です"), human(2, 1, "二つ目の引用です") ]
    result = call({ "人間の考え" => [ item("人間の考え", "一つ目の引用です"), item("人間の考え", "二つ目の引用です") ] }, humans)
    assert_equal [ [ "人間の考え:0", 1, "source" ], [ "人間の考え:1", 2, "source" ] ], links(result)
  end

  test "引用の正規化（NFKC・句読点・空白）を越えて照合する" do
    humans = [ human(1, 0, "データベースの 設計を、見直す。") ]
    result = call({ "人間の考え" => [ item("人間の考え", "データベースの設計を見直す") ] }, humans)
    assert_equal 1, result.links.size
  end

  test "同じ発言への複数項目のリンクは、item_key で区別される" do
    humans = [ human(1, 0, "AをBにします。CもDにします") ]
    result = call({ "決定" => [ item("決定", "AをBにします"), item("決定", "CもDにします") ] }, humans)
    assert_equal [ [ "決定:0", 1, "source" ], [ "決定:1", 1, "source" ] ], links(result)
  end
end
