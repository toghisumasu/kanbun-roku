require "test_helper"

# 複製元（kanbun-ka、コミット 65bb176）の spec/services/kanbun_translator_service_retry_spec.rb と
# kanbun_translator_service_normalize_spec.rb を minitest に移したもの。MeCab の呼び出しと Ollama は、インスタンスごとに偽物に差し替える。
class KanbunKa::KanbunTranslatorServiceTest < ActiveSupport::TestCase
  Service = KanbunKa::KanbunTranslatorService

  # MeCab は空の解析結果（EOS だけ）、Ollama は渡した応答を順に返す。構文解析は失敗する（骨格なし）。
  def service(text, *responses)
    instance = Service.new(text)
    queue = responses.dup
    instance.define_singleton_method(:run_mecab) { |_text| "EOS\n" }
    instance.define_singleton_method(:call_ollama) { |_prompt| queue.shift }
    instance
  end

  def normalize(raw) = Service.new("x").send(:normalize, raw)
  def drop(input, hakubun, skeleton) = Service.new(input).send(:drop_stray_question_marker, hakubun, skeleton)
  def restore_compound(hakubun, skeleton) = Service.new("").send(:restore_compound_words, hakubun, skeleton)
  def restore_subject(hakubun, skeleton) = Service.new("").send(:restore_leading_subject, hakubun, skeleton)

  test "白文の形：漢字と句読点だけなら白文。仮名や空白が混じれば白文ではない" do
    assert_match Service::HAKUBUN_PATTERN, "私不読漢文。"
    assert_no_match Service::HAKUBUN_PATTERN, "学ぶことは楽しゅう。"
    assert_no_match Service::HAKUBUN_PATTERN, "私 食 林檎"
  end

  test "再試行：仮名混じりの出力は 1 回だけ作り直し、直ればそれを使う" do
    result = service("花が咲き鳥が鳴く", "花が咲き鳥が鳴く。", "花開鳥啼").call
    assert_equal true, result.retried
    assert_equal "花開鳥啼", result.hakubun
    assert_nil result.parse_error
  end

  test "再試行：作り直しても直らなければ 2 回目の出力を使い、再試行は 1 回で止める" do
    result = service("人は皆死ぬ", "人の皆は死ぬ。", "人の皆死ぬ").call
    assert_equal true, result.retried
    assert_equal "人の皆死ぬ", result.hakubun
    assert_not_nil result.parse_error
  end

  test "再試行：最初から白文なら作り直さない" do
    result = service("私は漢文を読まない", "私不読漢文").call
    assert_equal false, result.retried
    assert_equal "私不[レ]読[二]漢文[一]", result.kunten
  end

  test "再試行：空白と 2 行目以降は取り除く" do
    result = service("私は漢文を読まない", "私 不 読 漢 文\n（説明）").call
    assert_equal "私不読漢文", result.hakubun
    assert_equal false, result.retried
  end

  test "骨格が作れない文は fallback になる" do
    assert_equal true, service("ダミー", "私不読漢文").call.fallback
  end

  test "normalize：繁体字・簡体字を日本の字体に直し、空白を除き、最初の 1 行だけ取る。文字列でなければそのまま" do
    assert_equal "先生教学生", normalize("先生教學生")
    assert_equal "国興国滅", normalize("國興國滅")
    assert_equal "不亦楽乎", normalize("不亦樂乎")
    assert_equal "老人帰山", normalize("老人歸山")
    assert_equal "氷莫如水冷", normalize("冰莫如水冷")
    assert_equal "勿笑此処", normalize("勿笑此处")
    assert_equal "彼不読書", normalize("彼 不 読書\n説明文")
    assert_nil normalize(nil)
  end

  test "drop_stray_question_marker：疑問でない文に混じった乎を除く。骨格や原文に疑問があれば残す。骨格がなければそのまま" do
    assert_equal "不学則不知道", drop("学ばなければ道を知らない", "不学則不知乎道", "不 学ぶ 則 不 知る 道")
    assert_equal "君学乎", drop("君は学ぶか", "君学乎", "君 学ぶ 乎")
    assert_equal "不亦楽乎", drop("楽しくないか", "不亦楽乎", "不 楽しい")
    assert_equal "山高於乎雲", drop("山は雲より高い", "山高於乎雲", nil)
  end

  test "restore_compound_words：縮められた漢語を元に戻す。残っている・辞書にある字への言い換え・骨格なしは触らない" do
    assert_equal "私自鹿児島能望見閃光", restore_compound("私自鹿児島能望閃光", "私 自 鹿児島 能 望見 閃光")
    assert_equal "私自鹿児島能望見閃光", restore_compound("私自鹿児島能望見閃光", "私 自 鹿児島 能 望見 閃光")
    assert_equal "子飲水", restore_compound("子飲水", "子供 飲む 水")
    assert_equal "私能望閃光", restore_compound("私能望閃光", nil)
  end

  test "restore_leading_subject：マーカーで始まる白文に、落とされた主語を戻す。それ以外は触らない" do
    assert_equal "私自鹿児島能望見閃光", restore_subject("自鹿児島能望見閃光", "私 自 鹿児島 能 望見 閃光")
    assert_equal "私自鹿児島能望見閃光", restore_subject("私自鹿児島能望見閃光", "私 自 鹿児島 能 望見 閃光")
    assert_equal "我自鹿児島来", restore_subject("我自鹿児島来", "私 自 鹿児島 来る")
    assert_equal "不学則不知道", restore_subject("不学則不知道", "不 学ぶ 則 不 知る 道")
    assert_equal "有足於蛇", restore_subject("有足於蛇", "有 足 於 蛇")
    assert_equal "食林檎", restore_subject("食林檎", "私 食べる 林檎")
  end

  test "MeCab（実物）と構文解析まで通る文は、骨格ができて fallback にならない（Ollama だけ偽物）" do
    skip "mecab がない" unless system("which mecab > /dev/null 2>&1")
    instance = Service.new("私は漢文を読まない")
    instance.define_singleton_method(:call_ollama) { |_prompt| "私不読漢文" }
    result = instance.call
    assert_equal false, result.fallback
    assert_not_nil result.skeleton
    assert_equal "私不読漢文", result.hakubun
  end
end
