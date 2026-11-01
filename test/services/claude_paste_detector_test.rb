require "test_helper"

# ダミーの文だけを使う。DBには触れない。
class ClaudePasteDetectorTest < ActiveSupport::TestCase
  CLAUDE = "この設計では、区切りは原本から計算できる派生情報として扱い、メッセージ本体には一切書き込まない方針にします。再計算はいつでもやり直せます。"

  def detector(*bodies, **options) = ClaudePasteDetector.new(bodies, **options)

  test "Claude の文をほぼそのまま貼った発言は該当する" do
    assert detector(CLAUDE).paste?(CLAUDE)
    assert detector(CLAUDE).paste?("これです\n#{CLAUDE}")
  end

  test "正規化（NFKC・句読点・空白の除去）の差は無視する" do
    changed = CLAUDE.delete("、。").gsub("方針", "方 針").tr("0-9", "０-９") + "！"
    assert detector(CLAUDE).paste?(changed)
    assert detector("ＡＢＣ#{CLAUDE}").paste?("abc #{CLAUDE}")
  end

  test "一致が50字未満なら該当しない" do
    short = ClaudePasteDetector.normalize(CLAUDE)[0, 49]
    assert_equal 49, short.size
    refute detector(CLAUDE).paste?(short)
    assert_equal 0, detector(CLAUDE).longest_match(short)
  end

  test "一致が50字以上なら、発言全体に占める割合に関係なく該当する" do
    quoted = ClaudePasteDetector.normalize(CLAUDE)[0, 60]
    assert detector(CLAUDE).paste?(quoted + "あ" * 40)
    assert detector(CLAUDE).paste?(quoted + "あ" * 2000)
    refute detector(CLAUDE).paste?(quoted[0, 49] + "あ" * 2000)
  end

  test "連続していない一致の合計は数えない" do
    n = ClaudePasteDetector.normalize(CLAUDE)
    pieces = n[0, 30] + "ああああ" + n[40, 30]
    refute detector(CLAUDE).paste?(pieces * 2)
    assert_operator detector(CLAUDE).longest_match(pieces), :<, 50
  end

  test "最長一致の長さを返す。複数の assistant の文のうち長いほうを取る" do
    n = ClaudePasteDetector.normalize(CLAUDE)
    other = "全然別の話題の文章です。" * 10 + n[0, 55]
    d = detector(other, CLAUDE)
    assert_equal n.size, d.longest_match(CLAUDE)
  end

  test "assistant の文が無い・短い発言は該当しない" do
    refute detector.paste?(CLAUDE)
    refute detector(CLAUDE).paste?("")
    refute detector(CLAUDE).paste?("はい")
  end

  test "analyze: 一致の長さ・正規化後の長さ・一致割合を返す" do
    n = ClaudePasteDetector.normalize(CLAUDE)
    info = detector(CLAUDE).analyze("前置き。#{CLAUDE}")
    assert_equal n.size, info.match_length
    assert_equal n.size + 3, info.size
    assert_in_delta n.size.fdiv(n.size + 3), info.ratio
    none = detector(CLAUDE).analyze("全く関係のない短い発言です")
    assert_equal 0, none.match_length
    assert_equal 0.0, detector(CLAUDE).analyze("").ratio
  end

  test "normalize_with_map: 正規化後の各文字が、元の文のどこから来たかを返す" do
    text = "Ａ、Ｂ 　ｃ"
    n, map = ClaudePasteDetector.normalize_with_map(text)
    assert_equal "ABc", n
    assert_equal [ [ 0, 1 ], [ 2, 3 ], [ 5, 6 ] ], map
    assert_equal n, ClaudePasteDetector.normalize(text)
  end

  test "normalize_with_map: 1文字が複数文字に展開されても、元の1文字に対応づける。半角カナの濁点も1つにまとめる" do
    n, map = ClaudePasteDetector.normalize_with_map("㌔の")
    assert_equal "キロの", n
    assert_equal [ [ 0, 1 ], [ 0, 1 ], [ 1, 2 ] ], map
    n, map = ClaudePasteDetector.normalize_with_map("ｶﾞ。")
    assert_equal "ガ", n
    assert_equal [ [ 0, 2 ] ], map
  end

  test "match_spans: 一致部分の元の文での範囲（句読点・空白を挟んでも元の位置に戻せる）" do
    text = "前置きです。\n#{CLAUDE}\n後ろです"
    spans = detector(CLAUDE).match_spans(text)
    assert_equal 1, spans.size
    assert_equal CLAUDE.size, spans.first.to - spans.first.from
    assert_equal CLAUDE, text[spans.first.from...spans.first.to]
    assert_equal ClaudePasteDetector.normalize(CLAUDE).size, spans.first.length
  end

  test "match_spans: 引用側の表記が違っても（全角・空白・句読点）元の位置へ戻る" do
    changed = CLAUDE.tr("0-9", "０-９").gsub("方針", "方 針")
    text = "あ。#{changed}。い"
    span = detector(CLAUDE).match_spans(text).first
    assert_equal changed + "。", text[span.from...span.to]
    assert_equal "あ。", text[0...span.from]
    assert_equal "い", text[span.to..]
  end

  test "match_spans: 離れた2か所の一致は別々に返す。すぐ隣り合う一致は1つにまとめる" do
    first = CLAUDE
    second = "全然別の文で、再計算はいつでもやり直せますし、原本には一切手を触れない仕組みを徹底して維持しますので、安心して作業を進めてください。"
    d = detector(first, second)
    assert_operator ClaudePasteDetector.normalize(second).size, :>=, 50
    assert_equal 2, d.match_spans("#{first}\n間の発言です\n#{second}").size
    assert_equal 1, d.match_spans("#{first}#{second}").size
  end

  test "mask: 一致した部分だけを置き換え、一致しない部分は残す。一致がなければそのまま" do
    text = "前置き\n#{CLAUDE}\n後ろ"
    assert_equal "前置き\n【貼】\n後ろ", detector(CLAUDE).mask(text, "【貼】")
    assert_equal "関係ない発言", detector(CLAUDE).mask("関係ない発言", "【貼】")
    assert_equal text, text # 元の文字列は変えない
  end

  test "remainder_size: 一致部分を除いて残る部分の正規化後の長さ" do
    d = detector(CLAUDE)
    assert_equal 0, d.remainder_size(CLAUDE)
    assert_equal 0, d.remainder_size("#{CLAUDE}。")
    assert_equal ClaudePasteDetector.normalize("前置きです").size, d.remainder_size("前置きです\n#{CLAUDE}")
  end

  Timed = Struct.new(:body, :occurred_at)

  test "before: その発言より前の時刻の assistant メッセージだけを照合する（同時刻・後のものは使わない）" do
    base = Time.utc(2026, 11, 1, 10)
    d = detector(Timed.new(CLAUDE, base))
    assert d.paste?(CLAUDE, before: base + 1)
    refute d.paste?(CLAUDE, before: base)
    refute d.paste?(CLAUDE, before: base - 1)
    assert d.paste?(CLAUDE) # before: を省けば制限しない
    assert_equal 0, d.longest_match(CLAUDE, before: base)
    assert_equal [], d.match_spans(CLAUDE, before: base - 1)
    assert_equal CLAUDE, d.mask(CLAUDE, "【貼】", before: base - 1)
    assert_equal "【貼】", d.mask(CLAUDE, "【貼】", before: base + 1)
  end

  test "before: 同じ文が前後に複数あれば、前のものとだけ照合する" do
    base = Time.utc(2026, 11, 1, 10)
    d = detector(Timed.new(CLAUDE, base + 60), Timed.new(CLAUDE, base - 60))
    assert d.paste?(CLAUDE, before: base)
    d2 = detector(Timed.new(CLAUDE, base + 60))
    refute d2.paste?(CLAUDE, before: base)
  end

  test "文字列で渡した assistant の文には時刻がなく、before: を指定してもつねに対象になる" do
    assert detector(CLAUDE).paste?(CLAUDE, before: Time.utc(2000, 1, 1))
  end
end
