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
  # SIMILAR_A と似ていて、決定語を含まない本文（再分類で移る項目に使う）。
  SIMILAR_C = "データベースの設計を見直す方針を確認したい"
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

  test "再分類（c）：引用か本文に決定語を含む項目は、語尾が対象でも移さず決定に残す（kept に記録）" do
    %w[ ください お願いします ますか ].each do |ending|
      in_quote = item("決定", "残る項目", "この方針にします。確認#{ending}")   # 引用に決定語
      in_text = item("決定", "この案を採用する", "確認#{ending}")             # 本文だけに決定語
      result = P.call([ chunk(decision: [ in_quote, in_text ]) ])
      assert_equal 2, result.items["決定"].size, ending
      assert_equal 0, result.items["人間の依頼・共有"].size, ending
      assert_equal [], result.moved, ending
      assert_equal 2, result.kept.size, ending
    end
  end

  test "再分類（c）：決定語を含まない項目は従来どおり移す。kept には入らない" do
    %w[ ください お願いします ますか ].each do |ending|
      result = P.call([ chunk(decision: [ item("決定", "確認の項目", "これを確認#{ending}") ]) ])
      assert_equal 0, result.items["決定"].size, ending
      assert_equal 1, result.items["人間の依頼・共有"].size, ending
      assert_equal 1, result.moved.size, ending
      assert_equal [], result.kept, ending
    end
  end

  test "再分類（c）：決定語の判定は NFKC のあと（全角半角の揺れを越える）" do
    wide = item("決定", "残る項目", "ＡＢＣを採用して確認してください")   # 引用は全角英字を含む
    kana = item("決定", "ﾃｽﾄを採用する", "確認してください")              # 本文は半角カナを含む
    result = P.call([ chunk(decision: [ wide, kana ]) ])
    assert_equal 2, result.items["決定"].size
    assert_equal 2, result.kept.size
    assert_equal [], result.moved
  end

  test "再分類（c）：語尾が対象でない決定や、決定以外の見出しは kept に入らない" do
    result = P.call([ chunk(decision: [ item("決定", "残る", "この方針にします") ], thought: [ item("人間の考え", "考え", "採用してください") ]) ])
    assert_equal [], result.kept
    assert_equal [], result.moved
  end

  test "再分類してから重複を落とす（移した項目も、決定との重複で落ちうる）" do
    result = P.call([ chunk(decision: [ item("決定", SIMILAR_A, "この方針にします"), item("決定", SIMILAR_C, "確認してください") ]) ])
    assert_equal [ SIMILAR_A ], texts(result, :decision)
    assert_equal [], texts(result, :request) # 移した SIMILAR_C は、決定の SIMILAR_A と似ているので落ちる
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

  def moved_headings(quote, heading: "決定")
    result = P.call([ chunk(decision: [ item(heading, "対象の項目", quote) ]) ])
    [ result.items["決定"].size, result.items["人間の依頼・共有"].size, result.items["未解決"].size, result.moved_by_rule ]
  end

  test "再分類（d）：決定の引用が ています・ております・中です で終わり、決定語を含まなければ、依頼・共有へ移す" do
    [ "作業を続けています", "作業を続けております。", "いま作業中です", "設定がそうなっています。", "作業を続けています！" ].each do |quote|
      kept, requests, open, by_rule = moved_headings(quote)
      assert_equal [ 0, 1, 0, 1 ], [ kept, requests, open, by_rule["d"] ], quote
    end
  end

  test "再分類（d）：決定語を含む・語尾が違う・決定以外の見出しは移さない" do
    [ "この方針にします。作業を続けています", "作業を続けます", "作業を続けています件" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal 1, kept, quote
      assert_equal 0, by_rule["d"], quote
    end
    thought = P.call([ chunk(thought: [ item("人間の考え", "考え", "作業を続けています") ]) ])
    assert_equal 1, thought.items["人間の考え"].size
    assert_equal 0, thought.moved_by_rule.values.sum
  end

  test "再分類（e）：決定の引用が しました・ました で終わる30字以内の短文で、決定語を含まなければ、依頼・共有へ移す" do
    [ "作業を完了しました", "作業が終わりました。", "あ" * 27 + "ました", "あ" * 26 + "しました" ].each do |quote|
      kept, requests, _open, by_rule = moved_headings(quote)
      assert_equal [ 0, 1, 1 ], [ kept, requests, by_rule["e"] ], quote
    end
  end

  test "再分類（e）：31字以上・決定語を含む・語尾が違うものは移さない" do
    [ "あ" * 27 + "しました", "あ" * 28 + "ました", "この方針にしました", "方針を決めました", "作業を完了します" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal 1, kept, quote
      assert_equal 0, by_rule["e"], quote
    end
  end

  test "再分類（f）：決定の引用が か？・か。 で終わるものは、決定語を含んでいても、未解決へ移す（NFKC のあと）" do
    [ "進めてもよいですか？", "進めてもよいですか?", "進めてもよいですか。", "この方針にしますか？", "この案を採用でよいですか。" ].each do |quote|
      kept, requests, open, by_rule = moved_headings(quote)
      assert_equal [ 0, 0, 1, 1 ], [ kept, requests, open, by_rule["f"] ], quote
    end
  end

  test "再分類（f）：か で終わらない・文の途中の か・決定以外の見出しは移さない" do
    [ "進めてもよいかを確認する", "進めてもよいか確認します", "進めてもよい" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal 1, kept, quote
      assert_equal 0, by_rule["f"], quote
    end
    thought = P.call([ chunk(thought: [ item("人間の考え", "考え", "進めてもよいですか？") ]) ])
    assert_equal 1, thought.items["人間の考え"].size
  end

  test "規則は c → d → e → f の順に見て、最初に当たったものだけが移す。規則別に数える" do
    result = P.call([ chunk(decision: [
      item("決定", "確認の依頼", "これを確認してください"), item("決定", "続行中の作業", "作業を続けています"),
      item("決定", "完了の報告", "作業を完了しました"), item("決定", "進めてよいかの質問", "進めてもよいですか？"),
      item("決定", "方針の表明", "この方針にします")
    ]) ])
    assert_equal({ "c" => 1, "d" => 1, "e" => 1, "f" => 1, "h" => 0, "i" => 0 }, result.moved_by_rule)
    assert_equal 4, result.moved.size
    assert_equal [ "方針の表明" ], result.items["決定"].map(&:text)
    assert_equal 3, result.items["人間の依頼・共有"].size
    assert_equal [ "進めてよいかの質問" ], result.items["未解決"].map(&:text)
  end

  test "機微情報の除外（g）：パスワードなどの語の前後20字以内に ASCII の連続が6字以上ある項目は、どの見出しでも落とす" do
    dropped = [
      item("決定", "本文", "パスワードは Ab3xY9zQ です"), item("人間の考え", "password: Ab3xY9zQ を設定", ""),
      item("未解決", "パスフレーズ（Zz9-Qq8-Xx7）を変更したい", ""), item("人間の依頼・共有", "本文だけ", "passphrase=Ab3xY9zQ")
    ]
    result = P.call([ chunk(decision: [ dropped[0] ], thought: [ dropped[1] ], open: [ dropped[2] ], request: [ dropped[3] ]) ])
    assert_equal [ 0, 0, 0, 0 ], Diary::Rules::HEADINGS.map { |h| result.items[h].size }
    assert_equal 4, result.sensitive.size
  end

  test "機微情報の除外（g）：連続が5字以下・20字より遠い・語そのものだけの項目は残す" do
    keep = [
      item("決定", "パスワードを変更する", "パスワードは ab12 です"), item("決定", "パスワード" + "あ" * 21 + "Ab3xY9zQ", ""),
      item("決定", "password を変更する", ""), item("決定", "Ab3xY9zQ" + "あ" * 21 + "パスワード", "")
    ]
    result = P.call([ chunk(decision: keep) ])
    assert_equal 4, result.items["決定"].size
    assert_equal [], result.sensitive
  end

  test "規則別の移動数（moved_by_rule）と除外した件数（sensitive）を数える" do
    post = P.call([ chunk(decision: [ item("決定", "d の項目", "作業を続けています"), item("決定", "g の項目", "パスワードは Ab3xY9zQ です") ]) ])
    assert_equal({ "c" => 0, "d" => 1, "e" => 0, "f" => 0, "h" => 0, "i" => 0 }, post.moved_by_rule)
    assert_equal 1, post.sensitive.size
  end

  test "再分類（h）：決定の引用がお礼・所感の語を含み、決定語も「〜します」も含まなければ、人間の考えへ移す" do
    [ "資料を整えてくれてありがとう", "今回の取り組みに感謝", "今日の作業はお疲れさま", "結果が良かった", "とても面白い試みだ", "分かりやすくて助かります。" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal [ 0, 1 ], [ kept, by_rule["h"] ], quote
    end
    result = P.call([ chunk(decision: [ item("決定", "お礼の項目", "資料を整えてくれてありがとう") ]) ])
    assert_equal [ "人間の考え" ], result.moved.map { |_, after| after.heading }
    assert_equal 1, result.items["人間の考え"].size
  end

  test "再分類（h）：お礼と「〜します」が1つの引用にあるもの（自分の行動の表明を含む型）は、移さず決定に残す" do
    [ "ありがとう。あとで共有します", "良かったです。帰ってから連携します", "感謝します", "すごい。明日から試します" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal [ 1, 0 ], [ kept, by_rule["h"] ], quote
    end
  end

  test "再分類（h）：お願いします・よろしくお願いします・お願いいたします は「〜します」に数えない" do
    assert_not Diary::PostProcessor.send(:commit_word?, "ありがとう。よろしくお願いします")
    assert_not Diary::PostProcessor.send(:commit_word?, "ありがとう。お願いいたします")
    assert Diary::PostProcessor.send(:commit_word?, "ありがとう。よろしくお願いします。あとで確認します")
    # 語尾が お願いします なら、先に再分類（c）が移す。お願いしますを含み、末尾が違うものは h が移す
    kept, _requests, _open, by_rule = moved_headings("ありがとう。よろしくお願いしますとのことです")
    assert_equal [ 0, 1 ], [ kept, by_rule["h"] ]
  end

  test "再分類（h）：決定語を含む・お礼の語がない・決定以外の見出しは移さない" do
    [ "ありがとう。この方針に決めた", "資料を整理した", "ありがとう。次は進めます" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal 1, kept, quote
      assert_equal 0, by_rule["h"], quote
    end
    thought = P.call([ chunk(thought: [ item("人間の考え", "考え", "資料を整えてくれてありがとう") ]) ])
    assert_equal 1, thought.items["人間の考え"].size
    assert_equal 0, thought.moved_by_rule.values.sum
  end

  test "再分類（i）：決定の引用が日本語を含まず、コマンドらしい形で始まれば、依頼・共有へ移す" do
    [ "git status", "bin/rails db:migrate", "$ cd ~/work/app", "bundle exec rake test", "ssh user@host", "sudo apt update", "ollama list" ].each do |quote|
      kept, requests, _open, by_rule = moved_headings(quote)
      assert_equal [ 0, 1, 1 ], [ kept, requests, by_rule["i"] ], quote
    end
  end

  test "再分類（i）：日本語を含む・コマンドで始まらない・空の引用は移さない" do
    [ "git status を実行します", "cd は移動のこと", "hello world", "database.yml", "" ].each do |quote|
      kept, _requests, _open, by_rule = moved_headings(quote)
      assert_equal 1, kept, quote
      assert_equal 0, by_rule["i"], quote
    end
  end

  test "規則は c → d → e → f → h → i の順に見る。先に当たった規則が移す" do
    result = P.call([ chunk(decision: [
      item("決定", "確認の依頼", "これを確認してください"), item("決定", "続行中の作業", "作業を続けています"),
      item("決定", "完了の報告", "作業を完了しました"), item("決定", "進めてよいかの質問", "進めてもよいですか？"),
      item("決定", "お礼の項目", "資料を整えてくれてありがとう"), item("決定", "端末の貼り付け", "git status"),
      item("決定", "方針の表明", "この方針にします")
    ]) ])
    assert_equal({ "c" => 1, "d" => 1, "e" => 1, "f" => 1, "h" => 1, "i" => 1 }, result.moved_by_rule)
    assert_equal [ "方針の表明" ], result.items["決定"].map(&:text)
    assert_equal [ "お礼の項目" ], result.items["人間の考え"].map(&:text)
    # お礼で「ました」止めの短文は、先に（e）が移す
    first = P.call([ chunk(decision: [ item("決定", "短いお礼", "ありがとうございました") ]) ])
    assert_equal({ "c" => 0, "d" => 0, "e" => 1, "f" => 0, "h" => 0, "i" => 0 }, first.moved_by_rule)
  end
end
