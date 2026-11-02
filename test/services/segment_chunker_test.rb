require "test_helper"

# ダミーの発言だけを使う。DBには触れない。
class SegmentChunkerTest < ActiveSupport::TestCase
  Msg = Struct.new(:role, :body)

  def user(body) = Msg.new("user", body)
  def assistant(body) = Msg.new("assistant", body)

  def chunk(messages, **options) = SegmentChunker.call(messages, **options)

  test "トークン見積もりは文字種別で、日本語のほうが1文字あたり重い" do
    assert_operator SegmentChunker.estimate_tokens("漢" * 100), :>, SegmentChunker.estimate_tokens("a" * 100)
    assert_operator SegmentChunker.estimate_tokens("あ" * 100), :>, SegmentChunker.estimate_tokens("a" * 100)
    assert_equal 0, SegmentChunker.estimate_tokens("")
  end

  test "較正の実測（実データ30件）の傾向: 漢字主体・かな主体・ASCII主体のどれも実測より多く見積もる" do
    # 実測の代表値（文字数→トークン数）。ダミーの文字列を同じ文字数で作って比べる。
    assert_operator SegmentChunker.estimate_tokens("漢" * 1000), :>=, 1380 # 漢字 実測の当てはめ 約1.38/字
    assert_operator SegmentChunker.estimate_tokens("あ" * 1000), :>=, 520  # かな 約0.51/字
    assert_operator SegmentChunker.estimate_tokens("a" * 1000), :>=, 220   # ASCII 約0.22/字
  end

  test "入力の上限（INPUT_LIMIT）は、A の指示文で計算した値と一致する" do
    instruction = Diary::Prompts::A::INSTRUCTION
    assert_equal SegmentChunker.input_limit(instruction), SegmentChunker::INPUT_LIMIT,
      "A の指示文を変えたら、INPUT_LIMIT を #{SegmentChunker.input_limit(instruction)} に直し、Diary::Rules::VERSION を上げる"
    assert_equal Diary::Prompts::A::OPTIONS[:num_predict], SegmentChunker::OUTPUT_RESERVE,
      "出力の確保分は、A の num_predict と同じにする"
    assert_equal 0, SegmentChunker::INPUT_LIMIT % 100
    reserved = SegmentChunker.estimate_tokens(instruction) + SegmentChunker::TEMPLATE_RESERVE + SegmentChunker::OUTPUT_RESERVE
    assert_operator SegmentChunker::INPUT_LIMIT + reserved, :<=, SegmentChunker::CONTEXT
    assert_operator SegmentChunker::INPUT_LIMIT + reserved, :>, SegmentChunker::CONTEXT - 100
  end

  test "短い区切りは1塊で、役割のラベルが付き、発言の順を保つ" do
    r = chunk([ user("おはよう"), assistant("おはようございます"), user("天気は") ])
    assert_equal 1, r.chunks.size
    assert_equal [ 0, 1, 2 ], r.chunks.first.items.map(&:index)
    assert_equal "【人間】おはよう\n\n【Claude】おはようございます\n\n【人間】天気は", r.chunks.first.text
  end

  test "空の区切りは塊を作らない" do
    r = chunk([])
    assert_empty r.chunks
    assert_equal 0, r.original_tokens
  end

  test "user は全文、assistant は先頭N文字に切り詰めて印を付ける" do
    body = "あ" * 50
    r = chunk([ user(body), assistant(body) ], assistant_head_chars: 10)
    items = r.chunks.flat_map(&:items)
    assert_equal body, items[0].text
    assert_equal "あ" * 10 + SegmentChunker::TRUNCATED_MARK, items[1].text
    assert_equal [ :truncated ], items[1].marks
    assert_empty items[0].marks
  end

  test "assistant が N 文字ちょうどなら切らない" do
    r = chunk([ assistant("あ" * 10) ], assistant_head_chars: 10)
    assert_equal "あ" * 10, r.chunks.first.items.first.text
  end

  test "コードブロックは（省略）に置き換える。閉じていないものも" do
    body = "実行した\n```ruby\nputs 1\nputs 2\n```\n結果は1だった"
    item = chunk([ user(body) ]).chunks.first.items.first
    assert_equal "実行した\n（省略）\n結果は1だった", item.text
    assert_equal [ :omitted ], item.marks

    unclosed = chunk([ user("続き\n```\nputs 1\nputs 2") ]).chunks.first.items.first
    assert_equal "続き\n（省略）", unclosed.text
  end

  test "コードブロックの置換は assistant の切り詰めより先に行う" do
    body = "```\n#{"x\n" * 500}```\n本文です"
    item = chunk([ assistant(body) ], assistant_head_chars: 50).chunks.first.items.first
    assert_equal "（省略）\n本文です", item.text
    assert_equal [ :omitted ], item.marks
  end

  test "長い引用は（省略）にし、短い引用は残す" do
    short = "> 短い引用\n本文"
    assert_equal short, chunk([ user(short) ]).chunks.first.items.first.text

    long = "前置き\n#{"> #{"引用" * 50}\n" * 5}後書き"
    item = chunk([ user(long) ]).chunks.first.items.first
    assert_equal "前置き\n（省略）\n後書き", item.text
  end

  test "上限を超えたら発言の境界で塊を分け、各塊は上限以内" do
    limit = 1000
    messages = Array.new(30) { |i| user("漢字#{i}" * 40) }
    r = chunk(messages, limit:)
    assert_operator r.chunks.size, :>=, 2
    assert r.chunks.all? { |c| c.tokens <= limit }, "塊が上限を超えた"
    # 発言は欠けず、重ならず、順に並ぶ
    assert_equal (0...30).to_a, r.chunks.flat_map { |c| c.items.map(&:index) }
    # 塊の文字列は発言の中で切れていない
    r.chunks.each { |c| assert_equal c.items.size, c.text.scan(/【人間】/).size }
  end

  test "塊のトークン数は連結した文字列の見積もりと一致する" do
    r = chunk(Array.new(12) { |i| user("あ" * 100 + "abc" * i) }, limit: 500)
    r.chunks.each { |c| assert_equal SegmentChunker.estimate_tokens(c.text), c.tokens }
  end

  test "単独で上限を超える発言は、先頭と末尾を残して間を省略する" do
    limit = 600
    head = "冒頭の文" * 5
    tail = "結びの文" * 5
    body = head + ("中" * 5000) + tail
    r = chunk([ user("前"), user(body), user("後") ], limit:)
    big = r.chunks.flat_map(&:items).find { |it| it.index == 1 }
    assert_includes big.marks, :middle
    assert big.text.start_with?("冒頭の文")
    assert big.text.end_with?("結びの文")
    assert_includes big.text, SegmentChunker::MIDDLE_MARK
    assert r.chunks.all? { |c| c.tokens <= limit }
    assert_equal 1, r.oversized
    assert_equal 1, r.raw_oversized
  end

  test "コードで大きい発言は、前処理で収まれば中略にならない" do
    body = "確認して\n```\n#{"x" * 100_000}\n```"
    r = chunk([ user(body) ], limit: 600)
    assert_equal 1, r.raw_oversized
    assert_equal 0, r.oversized
    assert_equal "【人間】確認して\n（省略）", r.chunks.first.text
  end

  test "前処理で減ったトークンを報告する" do
    r = chunk([ user("質問"), assistant("答え" * 1000) ], assistant_head_chars: 20)
    assert_operator r.processed_tokens, :<, r.original_tokens
  end

  test "入力の発言列は書き換えない" do
    body = "```\ncode\n```"
    message = user(body)
    chunk([ message ])
    assert_equal "```\ncode\n```", message.body
  end

  test "貼付は先頭と末尾の数行だけ残し、間の行数を示して省略する" do
    terminal = "alice@host d % ls\n" + (1..40).map { |i| "out#{i}" }.join("\n")
    item = chunk([ user(terminal) ]).chunks.first.items.first
    lines = item.text.lines.map(&:chomp)
    assert_equal "alice@host d % ls", lines.first
    assert_equal "out40", lines.last
    assert_equal "（貼付のため31行省略）", lines[SegmentChunker::PASTE_HEAD_LINES]
    assert_equal SegmentChunker::PASTE_HEAD_LINES + 1 + SegmentChunker::PASTE_TAIL_LINES, lines.size
    assert_includes item.marks, :pasted
  end

  test "trim_paste: false なら貼付を省略しない" do
    terminal = "alice@host d % ls\n" + (1..40).map { |i| "out#{i}" }.join("\n")
    item = chunk([ user(terminal) ], trim_paste: false).chunks.first.items.first
    assert_equal terminal, item.text
  end

  test "行数が少ない貼付や assistant の発言は貼付として省略しない" do
    short = "alice@host d % ls\na\nb"
    assert_equal short, chunk([ user(short) ]).chunks.first.items.first.text
    terminal = "alice@host d % ls\n" + (1..40).map { |i| "out#{i}" }.join("\n")
    item = chunk([ assistant(terminal) ], assistant_head_chars: 100_000).chunks.first.items.first
    assert_equal terminal, item.text
  end

  Raw = Struct.new(:role, :body, :raw)

  test "本文が空の user の発言には、入力でだけ使う印を入れる" do
    image = Raw.new("user", "", { "files" => [ { "file_name" => "a.png" } ] })
    document = Raw.new("user", "", { "attachments" => [ { "file_name" => "a.txt" } ] })
    both = Raw.new("user", "", { "content" => [ { "type" => "image" }, { "type" => "document" } ] })
    nothing = Raw.new("user", "  \n", { "files" => [], "attachments" => [] })
    no_raw = user("")
    items = chunk([ image, document, both, nothing, no_raw ]).chunks.flat_map(&:items)
    assert_equal %w[ （画像） （文書） （画像）（文書） （添付・本文なし） （添付・本文なし） ], items.map(&:text)
    assert_equal "【人間】（画像）", chunk([ image ]).chunks.first.text
  end

  test "印は入力にだけ入り、元の発言（body）は書き換えない" do
    message = Raw.new("user", "", { "files" => [ { "file_name" => "a.png" } ] })
    chunk([ message ])
    assert_equal "", message.body
  end

  test "本文のある発言には、添付があっても印を入れない" do
    message = Raw.new("user", "これを見て", { "files" => [ { "file_name" => "a.png" } ] })
    assert_equal "これを見て", chunk([ message ]).chunks.first.items.first.text
  end

  Timed = Struct.new(:role, :body, :raw, :occurred_at)

  def jst(*args) = ConversationSegmenter::JST.local(*args)

  test "human_block: 先頭に人間の発言ブロック（時刻つき）、続けて流れを置く。端末出力は入れない" do
    terminal = "alice@host d % ls\n" + (1..40).map { |i| "out#{i}" }.join("\n")
    messages = [
      Timed.new("user", "最初の依頼", {}, jst(2026, 10, 1, 9, 5)),
      Timed.new("assistant", "了解です", {}, jst(2026, 10, 1, 9, 6)),
      Timed.new("user", terminal, {}, jst(2026, 10, 1, 9, 7)),
      Timed.new("user", "", { "files" => [ { "file_name" => "a.png" } ] }, jst(2026, 10, 1, 9, 8))
    ]
    text = chunk(messages, human_block: true).chunks.first.text
    block, flow = text.split("\n\n【流れ】\n")
    assert_equal "【人間の発言】\n[09:05] 最初の依頼\n[09:08] （画像）", block
    assert_includes flow, "【人間】最初の依頼\n\n【Claude】了解です\n\n【人間】alice@host d % ls"
    assert_includes flow, "（貼付のため31行省略）"
    refute_includes block, "alice@host"
    assert_includes flow, "【人間】（画像）"
  end

  test "human_block: 日付をまたぐ区切りでは時刻に月日を付ける。時刻は日本時間" do
    messages = [
      Timed.new("user", "夜", {}, Time.utc(2026, 10, 1, 14, 30)), # JST 23:30
      Timed.new("user", "朝", {}, Time.utc(2026, 10, 1, 21, 10)) # JST 06:10 (翌日)
    ]
    block = chunk(messages, human_block: true).chunks.first.text.split("\n\n").first
    assert_equal "【人間の発言】\n[10/01 23:30] 夜\n[10/02 06:10] 朝", block
  end

  test "human_block: 人間の発言がなければ（なし）。時刻がなくても動く" do
    text = chunk([ assistant("こんにちは") ], human_block: true).chunks.first.text
    assert text.start_with?("【人間の発言】\n（なし）\n\n【流れ】\n【Claude】こんにちは")
    assert_includes chunk([ user("あ") ], human_block: true).chunks.first.text, "【人間の発言】\nあ\n"
  end

  test "human_block: 塊に分けても各塊は上限以内で、各塊のブロックはその塊の発言だけ" do
    limit = 800
    messages = Array.new(20) { |i| user("漢字#{i}" * 30) }
    r = chunk(messages, limit:, human_block: true)
    assert_operator r.chunks.size, :>=, 2
    assert r.chunks.all? { |c| c.tokens <= limit }
    r.chunks.each do |c|
      block = c.text.split("\n\n【流れ】\n").first
      assert_equal c.items.size, block.scan(/漢字\d+/).size / 30
    end
  end

  test "human_block: 単独で大きい発言は、2回載ることを見込んで上限以内に収める" do
    limit = 800
    r = chunk([ user("あ" * 20_000) ], limit:, human_block: true)
    assert r.chunks.all? { |c| c.tokens <= limit }
    assert_equal 1, r.oversized
  end

  test "human_block を使わなければ、今までの出力と同じ" do
    r = chunk([ user("あ"), assistant("い") ])
    assert_equal "【人間】あ\n\n【Claude】い", r.chunks.first.text
  end

  test "claude_paste: 一致した部分だけを印に置き換え、一致しない部分は残す。body は変えない" do
    claude = "この設計では、区切りは原本から計算できる派生情報として扱い、メッセージ本体には一切書き込まない方針にします。"
    detector = ClaudePasteDetector.new([ claude ])
    pasted = user("これを見て\n#{claude}\n続きの質問です")
    normal = user("次の質問です")
    r = chunk([ pasted, normal ], claude_paste: detector)
    items = r.chunks.first.items
    assert_equal "これを見て\n（Claude文の貼り付け）\n続きの質問です", items.first.text
    assert_includes items.first.marks, :claude_paste
    assert_equal "次の質問です", items.last.text
    assert_equal "これを見て\n#{claude}\n続きの質問です", pasted.body
    # 全部が一致なら、印だけになる
    assert_equal "（Claude文の貼り付け）", chunk([ user(claude) ], claude_paste: detector).chunks.first.items.first.text
    # 検出器を渡さなければ、今までどおり本文を渡す
    assert_includes chunk([ pasted ]).chunks.first.text, "この設計では"
  end
  Stamped = Struct.new(:role, :body, :raw, :occurred_at)

  test "claude_paste: 発言より後の時刻の assistant メッセージとは照合しない" do
    claude = "この設計では、区切りは原本から計算できる派生情報として扱い、メッセージ本体には一切書き込まない方針にします。"
    at = Time.utc(2026, 11, 1, 10)
    later = ClaudePasteDetector.new([ Struct.new(:body, :occurred_at).new(claude, at + 60) ])
    earlier = ClaudePasteDetector.new([ Struct.new(:body, :occurred_at).new(claude, at - 60) ])
    message = Stamped.new("user", "これ\n#{claude}", {}, at)
    assert_includes chunk([ message ], claude_paste: later).chunks.first.items.first.text, "この設計では"
    assert_equal "これ\n（Claude文の貼り付け）", chunk([ message ], claude_paste: earlier).chunks.first.items.first.text
  end

  test "claude_paste: 残りにシェルのプロンプト行があれば paste_text として扱う（人間の発言ブロックに入れず、貼付を省略）" do
    claude = "この設計では、区切りは原本から計算できる派生情報として扱い、メッセージ本体には一切書き込まない方針にします。"
    detector = ClaudePasteDetector.new([ claude ])
    out = (1..30).map { |i| "出力#{i}" }.join("\n")
    moved = user("alice@host d %\n#{out}\n#{claude}")
    plain = user("ただの質問\n#{claude}")
    r = chunk([ moved, plain ], claude_paste: detector, human_block: true)
    items = r.chunks.first.items
    assert_includes items[0].marks, :moved_to_paste_text
    assert_includes items[0].marks, :pasted
    assert_equal false, items[0].human
    assert_includes items[0].text, "（貼付のため"
    assert_includes items[0].text, "（Claude文の貼り付け）"
    assert_equal true, items[1].human
    refute_includes items[1].marks, :moved_to_paste_text
    block = r.chunks.first.text.split("\n\n【流れ】\n").first
    refute_includes block, "alice@host"
    assert_includes block, "ただの質問"
  end

  test "flow: false は、人間の発言ブロックだけ（見出しなし、1発言1行）。assistant・端末出力・流れは入れない" do
    terminal = "alice@host d % ls\n" + (1..30).map { |i| "out#{i}" }.join("\n")
    messages = [
      Timed.new("user", "最初の依頼", {}, jst(2026, 10, 1, 9, 5)),
      Timed.new("assistant", "返答はこちらです", {}, jst(2026, 10, 1, 9, 6)),
      Timed.new("user", terminal, {}, jst(2026, 10, 1, 9, 7)),
      Timed.new("user", "", { "files" => [ { "file_name" => "a.png" } ] }, jst(2026, 10, 1, 9, 8))
    ]
    chunk = chunk(messages, human_block: true, flow: false).chunks.first
    assert_equal "[09:05] 最初の依頼\n[09:08] （画像）", chunk.text
    assert_equal [ 0, 3 ], chunk.items.map(&:index)
    refute_includes chunk.text, "返答"
    refute_includes chunk.text, "alice@host"
    refute_includes chunk.text, "【流れ】"
  end

  test "flow: false の塊の数は、人間の発言の分だけで決まる（assistant の長い発言は数えない）" do
    humans = Array.new(6) { |i| Timed.new("user", "漢字#{i}" * 40, {}, jst(2026, 10, 1, 9, i)) }
    giants = Array.new(6) { |i| Timed.new("assistant", "あ" * 5000, {}, jst(2026, 10, 1, 9, 10 + i)) }
    only_a = chunk(humans + giants, limit: 1000, human_block: true, flow: false)
    with_flow = chunk(humans + giants, limit: 1000, human_block: true)
    assert_operator only_a.chunks.size, :<, with_flow.chunks.size
    assert only_a.chunks.all? { |c| c.tokens <= 1000 }
    assert_equal (0...6).to_a, only_a.chunks.flat_map { |c| c.items.map(&:index) }
  end

  test "flow: false では、単独で大きい人間の発言は、ブロックに1回しか入らないので、上限いっぱいまで残す" do
    limit = 800
    big = Timed.new("user", "あ" * 20_000, {}, jst(2026, 10, 1, 9, 0))
    flow_false = chunk([ big ], limit:, human_block: true, flow: false)
    flow_true = chunk([ big ], limit:, human_block: true)
    assert flow_false.chunks.all? { |c| c.tokens <= limit }
    assert_operator flow_false.chunks.first.items.first.text.size, :>, flow_true.chunks.first.items.first.text.size
  end

  test "flow: false には human_block: true が要る" do
    assert_raises(ArgumentError) { chunk([ user("あ") ], flow: false) }
  end

  test "flow: false で人間の発言がなければ、塊は作らない" do
    assert_empty chunk([ assistant("返答だけ") ], human_block: true, flow: false).chunks
  end
end
