require "test_helper"

# ダミーの発言だけを使う。DBには触れない。
class MessageClassifierTest < ActiveSupport::TestCase
  def classify(body, role: "user", raw: nil) = MessageClassifier.classify(role:, body:, raw:)

  test "短い普通の発言は utterance" do
    assert_equal :utterance, classify("今日は天気がいい")
  end

  test "assistant の発言はどれだけ長くても utterance" do
    long = Array.new(50) { |i| "行#{i} " + "あ" * 40 }.join("\n")
    assert_equal :utterance, classify(long, role: "assistant")
    assert_equal :utterance, classify("", role: "assistant", raw: { "files" => [ { "file_name" => "a.png" } ] })
  end

  test "シェルのプロンプト行を含む複数行は paste_text" do
    zsh = "alice@host proj % ls\nGemfile\nREADME.md\n"
    assert_equal :paste_text, classify(zsh)
    assert_equal :paste_text, classify("$ ls\na\nb")
    assert_equal :paste_text, classify("(venv) alice@host dir % python x.py\nok\ndone")
    assert_equal :paste_text, classify("❯ ls\na\nb")
  end

  test "プロンプト行があっても行数が少なければ貼り付けにしない" do
    assert_equal :utterance, classify("$ ls\nこれを実行した")
    assert_equal :utterance, classify("$ ls")
  end

  test "プロンプトの形に見えない行は貼り付けにしない" do
    assert_equal :utterance, classify("価格は$100です\n安い\nと思う")
    assert_equal :utterance, classify("メール a@b.com に送った\n返事は\nまだ")
  end

  test "長い複数行は paste_text。行数か文字数が足りなければ utterance" do
    lines = MessageClassifier::PASTE_MIN_LINES
    long = Array.new(lines) { "あ" * (MessageClassifier::PASTE_MIN_CHARS / lines + 1) }.join("\n")
    assert_equal :paste_text, classify(long)
    assert_equal :utterance, classify(Array.new(lines - 1) { "あ" * 100 }.join("\n"))
    assert_equal :utterance, classify("あ" * (MessageClassifier::PASTE_MIN_CHARS * 2))
    assert_equal :utterance, classify(Array.new(lines) { "あ" }.join("\n"))
  end

  test "本文が空で image / document があれば paste_media" do
    assert_equal :paste_media, classify("", raw: { "content" => [ { "type" => "image" } ] })
    assert_equal :paste_media, classify("  \n", raw: { "content" => [ { "type" => "document" } ] })
    assert_equal :paste_media, classify("", raw: { "files" => [ { "file_name" => "x.PNG" } ] })
    assert_equal :paste_media, classify("", raw: { "attachments" => [ { "file_name" => "x.txt" } ] })
  end

  test "本文が空でも、貼付の手がかりがなければ utterance" do
    assert_equal :utterance, classify("", raw: {})
    assert_equal :utterance, classify("", raw: nil)
    assert_equal :utterance, classify("", raw: { "content" => [ { "type" => "text" } ], "files" => [], "attachments" => [] })
  end

  test "本文があれば media があっても paste_media にはしない" do
    assert_equal :utterance, classify("これを見て", raw: { "files" => [ { "file_name" => "a.png" } ] })
  end

  test "media の種類: files は拡張子で image / document、拡張子なしは document" do
    raw = { "files" => [ { "file_name" => "a.jpg" }, { "file_name" => "notes" }, { "file_name" => "b.pdf" } ] }
    assert_equal %i[ image document ], MessageClassifier.media_kinds(raw)
    assert_equal :both, MessageClassifier.media_label(raw)
    assert_equal :image, MessageClassifier.media_label({ "content" => [ { "type" => "image" } ] })
    assert_equal :neither, MessageClassifier.media_label(nil)
  end

  test "prompt_line?: プロンプトだけの行・~ $・Password:・進捗の NN% も端末出力とみなす" do
    [ "alice@host kanbun-roku %", "alice@host d % ls", "~ $", "~/proj $ ls", "(venv) ~ %", "$ ls",
      "Password:", "password: ", " 45%|████      | 45/100", "100% done", "12%" ].each do |line|
      assert MessageClassifier.prompt_line?(line), line
    end
  end

  test "prompt_line?: 普通の文・文末の割合・メールアドレスだけの行は端末出力としない" do
    [ "今日は晴れでした", "進捗は50%です", "割合は 50%", "連絡は alice@example.com まで", "価格は$100です",
      "これは~の記号です", "" ].each do |line|
      refute MessageClassifier.prompt_line?(line), line
    end
  end

  test "prompt_lines?: 行数の下限なしで、1行でもあれば真" do
    assert MessageClassifier.prompt_lines?("前置き\nPassword:")
    assert MessageClassifier.prompt_lines?("alice@host d %")
    refute MessageClassifier.prompt_lines?("前置き\n後書き")
  end
end
