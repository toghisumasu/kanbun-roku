require "test_helper"

# ダミーの発言だけを使う。DBには触れない。
class Diary::QuoteVerifierTest < ActiveSupport::TestCase
  V = Diary::QuoteVerifier

  OWN = "最初の依頼です。データベースの設計を見直したいと考えています。\n次の作業は来週にします。\nはい"
  OTHER = "こちらの提案は、テーブルを分ける方針です。実装は簡単です。"

  def item(quote, text: "本文", heading: "人間の考え") = Diary::Item.new(heading:, text:, quote:)

  def status(quote, own: OWN, other: OTHER, text: "本文") = V.verify(item(quote, text:), own:, other:)

  test "引用が、対応する側の発言に含まれれば pass" do
    assert_equal :pass, status("データベースの設計を見直したい")
  end

  test "正規化（NFKC・空白・句読点・記号・括弧・アスタリスク・バッククォート）の差は無視する" do
    assert_equal :pass, status("データベースの 設計を、見直したい")
    assert_equal :pass, status("「**データベースの設計**を見直したい」")
    assert_equal :pass, status("`データベースの設計を見直したい`")
    assert_equal :pass, status("ＡＢＣの設定", own: "ABC の設定を試した。そのあと確認した。")
  end

  test "引用が空なら no_quote。本文が免除の文言を含めば exempt" do
    assert_equal :no_quote, status("")
    assert_equal :no_quote, status("   ")
    assert_equal :exempt, status("", text: "画像・文書を共有した")
    assert_equal :exempt, status("", text: "資料として画像・文書を共有した。")
    assert_equal :no_quote, status("", text: "画像を共有した") # 免除の文言そのものを含まない
  end

  test "対応する側にない引用は not_in_input、逆の発言者の発言にだけあれば wrong_label" do
    assert_equal :not_in_input, status("どこにも書かれていない長めの引用の文字列です")
    assert_equal :wrong_label, status("テーブルを分ける方針です")
  end

  test "引用に貼り付けの印を含むときは mark_in_quote" do
    assert_equal :mark_in_quote, status("（Claude文の貼り付け）次の作業は")
    mark_own = "前置き（Claude文の貼り付け）後ろ。"
    assert_equal :mark_in_quote, status("（Claude文の貼り付け）", own: mark_own)
  end

  test "文末の短い断片（正規化後10字未満）は short_fragment。文全体が短い発言は断片としない" do
    assert_equal :short_fragment, status("来週にします")             # 文の途中から始まり、文末で終わる
    assert_equal :pass, status("次の作業は来週にします")               # 10字以上
    assert_equal :pass, status("はい")                               # 文全体（文頭から文末まで）が短い発言
    assert_equal :pass, status("次の作業")                           # 短いが、文末ではない（文の途中）
  end

  test "短い引用が、断片の位置にも文頭の位置にも現れるときは、断片として扱う" do
    own = "了解です。確認します\n確認します。"
    assert_equal :short_fragment, status("確認します", own:)
  end

  test "ちょうど10字は断片としない" do
    own = "そして次の作業は来週にします。"
    quote = "次の作業は来週にします" # 11字
    assert_equal :pass, status(quote, own:)
    ten = "作業は来週にします" # 9字 → 断片
    assert_equal :short_fragment, status(ten, own:)
    ten_chars = "の作業は来週にします" # 10字ちょうど
    assert_equal 10, V.normalize(ten_chars).size
    assert_equal :pass, status(ten_chars, own:)
  end

  test "verify_all は、状態ごとの件数と total / fail を返す（total は exempt を除く）" do
    items = [
      item("データベースの設計を見直したい"),
      item("来週にします"),
      item("", text: "画像・文書を共有した"),
      item(""),
      item("テーブルを分ける方針です"),
      item("書かれていない長めの文字列を引用している")
    ]
    result = V.verify_all(items, own: OWN, other: OTHER)
    assert_equal %i[ pass short_fragment exempt no_quote wrong_label not_in_input ], result.verdicts.map(&:last)
    counts = result.counts
    assert_equal 5, counts[:total]
    assert_equal 1, counts[:pass]
    assert_equal 4, counts[:fail]
    assert_equal 1, counts[:exempt]
    assert_equal 1, counts[:no_quote]
    assert_equal 1, counts[:wrong_label]
    assert_equal 1, counts[:not_in_input]
    assert_equal 1, counts[:short_fragment]
  end

  test "項目が空でも動く" do
    result = V.verify_all([], own: OWN, other: OTHER)
    assert_equal 0, result.counts[:total]
    assert_equal [], result.verdicts
  end

  test "意味のずれ（誤読）は検出できない: 引用が入力にあれば、本文が違っていても pass" do
    assert_equal :pass, status("データベースの設計を見直したい", text: "全く別の内容を書いた本文")
  end
end
