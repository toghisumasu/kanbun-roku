require "test_helper"

class ClassificationReportTest < ActiveSupport::TestCase
  Msg = Struct.new(:role, :body, :raw)

  def user(body, raw = {}) = Msg.new("user", body, raw)
  def assistant(body) = Msg.new("assistant", body, {})

  test "分類・空の発言の内訳・区切りの型・削減率・文字数を数える" do
    terminal = "alice@host d % ls\n" + Array.new(40) { |i| "out#{i}" }.join("\n")
    work = [ user(terminal), user("", { "files" => [ { "file_name" => "a.png" } ] }), assistant("了解") ]
    talk = [ user("こんにちは"), assistant("はい"), user("元気"), user("", { "attachments" => [ { "file_name" => "a.txt" } ] }),
             user(""), user("天気") ]
    report = ClassificationReport.build([ work, talk ])

    assert_equal({ paste_text: 1, paste_media: 2, utterance: 4 }, report[:user_classes].slice(:paste_text, :paste_media, :utterance))
    assert_equal({ image: 1, document: 1, neither: 1 }, report[:empty_user].to_h.slice(:image, :document, :neither))
    assert_equal({ work: 1, talk: 1 }, report[:segment_types].to_h)
    assert_operator report[:tokens][:with_paste], :<, report[:tokens][:without_paste]
    assert_equal({ n: 6, min: 0, max: 5 }, report[:utterance_chars]["all"].slice(:n, :min, :max))
    assert_includes ClassificationReport.text(report), "paste_text=1"
  end

  test "区切りが無くても報告できる" do
    report = ClassificationReport.build([])
    assert_equal 0, report[:segments]
    assert_kind_of String, ClassificationReport.text(report)
  end
end
