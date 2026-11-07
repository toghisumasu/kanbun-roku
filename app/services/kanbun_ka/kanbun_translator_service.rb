# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の app/services/kanbun_translator_service.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。
# 変更点: lexicon の require を lib/kanbun_ka/lexicon への Rails.root 基準のパスに変えた。

require "open3"
require "net/http"
require "json"
require Rails.root.join("lib/kanbun_ka/lexicon").to_s

module KanbunKa
class KanbunTranslatorService
  OLLAMA_URL   = "http://localhost:11434/api/generate".freeze
  OLLAMA_MODEL = "qwen3:8b".freeze

  Result = Struct.new(
    :hakubun,      # 漢文白文
    :kunten,       # 訓点付き漢文
    :kakikudashi,  # 書き下し文
    :skeleton,     # SkeletonBuilder出力（デバッグ用）
    :fallback,     # true = BNFパース失敗でLLM全文委譲
    :parse_error,  # nil = 訓点付与に成功 / 文字列 = Raccパーサーが解析できなかった理由
    :retried,      # true = LLM の出力が白文でなかった（仮名混じりなど）ため 1 回だけ再生成した
    keyword_init: true
  )

  # 白文として受け入れる形：漢字と句読点だけ。仮名・英数字・空白・説明文を含むものは白文ではない。
  HAKUBUN_PATTERN = /\A[\p{Han}、。]+\z/

  # LLM に渡す書き方の約束と見本。見本は Racc パーサーが解析できる形だけを選ぶ
  # （LLM が見本の文体に寄るほど、後段の返り点付与が成功しやすい）。
  HAKUBUN_RULES = <<~RULES.freeze
    【白文の書き方（厳守）】
    ・漢字だけで書く。ひらがな・カタカナ・英数字・空白・説明は一切書かない
    ・語順は 主語＋述語＋目的語。助詞（は・が・を・に・の・て）は書かない
    ・否定は 不・非・無 を述語の直前に置く（勿 は禁止専用で、否定には使わない）
    ・活用語尾（ぶ・しい・く）を残さず、語幹の漢字だけにする
    ・疑問は文末に 乎 を置く（〜か）。「どうして〜のか」は 何為〜
    ・禁止「〜てはいけない」は 勿＋述語
    ・比較「AはBより〜」は A＋形容詞＋於＋B
    ・「〜ても」は 雖。「もし〜ならば、〜」は 若〜則〜（否定は 若不〜則〜）
    ・「これ・それ」は 此、「あれ」は 彼 と書く
    ・「誰が〜のか」は 誰＋述語（乎は付けない）
    ・「〜なければ〜ない」は 不〜則不〜
    ・「〜ないことはない」は 無不＋述語＋目的語。「〜ない人（者）はいない」は 無不＋述語＋者
    ・「何も〜ない」は 主語＋無所＋述語
    ・「ただAだけが〜」は 惟＋A＋述語＋目的語
    ・乎 は、原文が「か」で終わる疑問文にだけ付ける（「〜ないか」は 不〜乎）。疑問でない文には付けない
    ・「Aしないのは恥ではない」のような否定の連続は 不A非恥 と並べる
    ・修飾する語は名詞の前に置く（高い山 → 高山）
    ・「Aと〜する」は 与A＋述語。「〜して〜する」は 〜而〜
    ・使役「AにBさせる」は 使A＋B。受身「AにBされる」は B於A
    ・場所「Aで〜する」は 述語＋目的語＋於＋A
    ・起点「Aから／Aより〜する」（比較の「より」とは別）は 自A＋述語。可能「〜できる」「〜し得る」は 能＋述語
    ・骨格に「自 A」があるときは、そのまま 自A の形で述語の前に置く（語順を変えない）。「能」があれば述語の直前
    ・日本の漢字（学・楽・帰・処）で書き、簡体字・繁体字は使わない
    例）原文：彼は書を読まない → 白文：彼不読書
    例）原文：月は明るく風は清い → 白文：月明風清
    例）原文：君子は道を学ぶ → 白文：君子学道
    例）原文：茶を飲んで書を読む → 白文：飲茶読書
    例）原文：彼は君子ではない → 白文：彼非君子
    例）原文：人を待ってはいけない → 白文：勿待人
    例）原文：どうして国に帰るのか → 白文：何為帰国
    例）原文：山は雲より高い → 白文：山高於雲
    例）原文：小さくても美しい → 白文：小雖美
    例）原文：もし来なければ → 白文：若不来
    例）原文：もし飲まなければ死ぬ → 白文：若不飲則死
    例）原文：嬉しくないか → 白文：不亦喜乎
    例）原文：誰が笑うのか → 白文：誰笑
    例）原文：耕さなければ飢える → 白文：不耕則飢
    例）原文：聞かなければ分からない → 白文：不聞則不知
    例）原文：言わないことはない → 白文：無不言
    例）原文：書を読まないことはない → 白文：無不読書
    例）原文：笑わない人はいない → 白文：無不笑者
    例）原文：客は何も言わない → 白文：客無所言
    例）原文：ただ犬だけが肉を食べる → 白文：惟犬食肉
    例）原文：見ないのは恥ではない → 白文：不見非恥
    例）原文：高い山に雲がある → 白文：高山有雲
    例）原文：師と茶を飲んで書を読む → 白文：与師飲茶而読書
    例）原文：父は子に書を読ませた → 白文：父使子読書
    例）原文：鹿は虎に食べられた → 白文：鹿食於虎
    例）原文：庭で花を見る → 白文：見花於庭
    例）原文：山より海を見る → 白文：自山見海
    例）原文：泳ぐことができる → 白文：能泳
    例）原文：弟は京都から手紙を送ることができる → 白文：弟自京都能送書
  RULES

  def self.call(japanese_text)
    new(japanese_text).call
  end

  def initialize(japanese_text)
    @input = japanese_text.strip
  end

  def call
    # Step 1: 形態素解析
    tokens = MeCabAdapter.call(run_mecab(@input))

    # Step 2: 構文解析（失敗してもnil、例外は出さない）
    parse_result = KanbunBNFParser.new(tokens).parse

    # Step 3: 骨格生成
    skeleton = parse_result ? SkeletonBuilder.call(parse_result) : nil

    # Step 4: LLM → 漢文白文
    fallback = skeleton.nil?
    prompt   = build_prompt(@input, skeleton)
    hakubun  = normalize(call_ollama(prompt))

    # Step 4b: 白文でない出力（仮名混じりなど）は、見本つきで 1 回だけ作り直す
    retried = false
    if retry_needed?(hakubun)
      retried = true
      hakubun = normalize(call_ollama(build_retry_prompt(prompt, hakubun)))
    end

    # Step 4c: 疑問でない文に LLM が付けた乎を除く（骨格と原文が疑問でないと言っているとき）
    hakubun = drop_stray_question_marker(hakubun, skeleton)

    # Step 4d: 骨格の漢語（望見・閃光など）を LLM が縮めて辞書にない字になったら、元の語に戻す
    hakubun = restore_compound_words(hakubun, skeleton)

    # Step 4e: LLM が落とした主語（骨格の先頭の語）を、白文が構造マーカーで始まるときだけ戻す
    hakubun = restore_leading_subject(hakubun, skeleton)

    # Step 5: Raccパーサー → 訓点・書き下し文
    kunten_result = KanbunParserService.call(hakubun)

    Result.new(
      hakubun:     hakubun,
      kunten:      kunten_result[:kunten],
      kakikudashi: kunten_result[:kakikudashi],
      skeleton:    skeleton,
      fallback:    fallback,
      parse_error: kunten_result[:error],
      retried:     retried
    )
  end

  private

  # LLM は繁体字・簡体字で返すことがある（學生・樂・处）。辞書は日本の字体なので、よくある字だけ直す。
  TRADITIONAL = {
    "學" => "学", "國" => "国", "讀" => "読", "來" => "来", "與" => "与", "實" => "実",
    "對" => "対", "變" => "変", "氣" => "気", "會" => "会", "樂" => "楽", "歸" => "帰",
    "處" => "処", "冰" => "氷", "說" => "説",
    "处" => "処", "乐" => "楽", "归" => "帰", "书" => "書", "读" => "読", "无" => "無", "风" => "風",
    "马" => "馬", "见" => "見", "闻" => "聞", "饮" => "飲", "说" => "説", "语" => "語",
    "话" => "話", "时" => "時", "间" => "間", "为" => "為", "鸟" => "鳥", "门" => "門"
  }.freeze

  # LLM の出力を白文の形に整える：最初の 1 行だけ取り、空白を除き、繁体字を日本の字体にする。
  def normalize(raw)
    return raw unless raw.is_a?(String)

    raw.lines.first.to_s.delete(" 　\t\r\n").gsub(/[#{TRADITIONAL.keys.join}]/, TRADITIONAL)
  end

  # 骨格があり、骨格にも原文にも疑問（乎・か）がないのに、白文に 乎 が混じっていたら除く。
  # 例）不学則不知道 に LLM が 不学則不知乎道 と余計な乎を入れた（Phase 4t）。
  # 乎 を足す向きはしない（何為〜 のように、疑問でも乎を付けない形があるため）。
  def drop_stray_question_marker(hakubun, skeleton)
    return hakubun unless hakubun.is_a?(String) && skeleton.is_a?(String)
    return hakubun if skeleton.include?("乎") || @input.include?("か")

    hakubun.delete("乎")
  end

  # 骨格にある漢字だけの語（2字以上）を LLM が縮めたとき、元の語に戻す（Phase 4x）。
  # 例）骨格 私 自 鹿児島 能 望見 閃光 に対し 私自鹿児島能望閃光 → 私自鹿児島能望見閃光。
  # 戻すのは、骨格の語が辞書にあり、縮んだ形（先頭部分）が辞書にない場合だけ。
  # 辞書にある字への言い換え（子供 → 子）はそのままにする。
  def restore_compound_words(hakubun, skeleton)
    return hakubun unless hakubun.is_a?(String) && skeleton.is_a?(String)

    skeleton.split.each do |word|
      next unless word.length >= 2 && word.match?(/\A\p{Han}+\z/)
      next unless Kanbun::Lexicon::TABLE.key?(word)
      next if hakubun.include?(word)

      (word.length - 1).downto(1) do |n|
        prefix = word[0, n]
        next if Kanbun::Lexicon::TABLE.key?(prefix)
        next unless hakubun.scan(prefix).size == 1

        hakubun = hakubun.sub(prefix, word)
        break
      end
    end
    hakubun
  end

  # 白文が構造マーカー（自・不・能…）で始まっているのに、骨格の先頭の語（主語）が白文にない
  # ときだけ、その語を先頭に戻す（Phase 4x）。
  # 例）骨格 私 自 鹿児島 能 望見 閃光 に対し 自鹿児島能望見閃光 → 私自鹿児島能望見閃光。
  # 骨格自身がマーカーで始まる文（不学則… 有足於蛇 など）や、主語を別の語に言い換えた場合は触らない。
  SUBJECT_STOP_MARKERS = %w[自 不 能 無 有 勿 若 使 惟 与 非 被 何].freeze

  def restore_leading_subject(hakubun, skeleton)
    return hakubun unless hakubun.is_a?(String) && skeleton.is_a?(String)

    first = skeleton.split.first
    return hakubun unless first&.match?(/\A\p{Han}+\z/)
    return hakubun if SUBJECT_STOP_MARKERS.include?(first)
    return hakubun unless Kanbun::Lexicon::TABLE.key?(first)
    return hakubun if hakubun.include?(first)
    return hakubun unless SUBJECT_STOP_MARKERS.include?(hakubun[0])

    first + hakubun
  end

  # 文字列で、空でなく、白文の形でないときだけ作り直す（nil・空は作り直しても変わらない）。
  def retry_needed?(hakubun)
    hakubun.is_a?(String) && !hakubun.empty? && !hakubun.match?(HAKUBUN_PATTERN)
  end

  def build_retry_prompt(prompt, previous)
    <<~PROMPT
      #{prompt}
      【前回の出力】#{previous}
      前回の出力には漢字と句読点以外の文字が含まれていました。
      上の「白文の書き方」と例に従い、漢字だけで書き直してください。白文のみ・1行。
      白文：
    PROMPT
  end

  # ---------------------------------------------------------
  # MeCab 呼び出し（Open3でシェルインジェクション対策）
  # ---------------------------------------------------------
  def run_mecab(text)
    stdout, _stderr, status = Open3.capture3("mecab", stdin_data: text)
    raise "MeCab failed: #{_stderr}" unless status.success?
    stdout
  end

  # ---------------------------------------------------------
  # LLMプロンプト: 骨格ありとなしで切り替える
  # ---------------------------------------------------------
  def build_prompt(original, skeleton)
    if skeleton
      # 骨格に実際に含まれるマーカーだけ抽出
      all_markers  = %w[不 使 被 有 無 莫如 不若 於 矣 乎 自 能]
      used_markers = all_markers.select { |m| skeleton.include?(m) }
      marker_note  = used_markers.empty? ? "なし" : used_markers.join(" ")

      <<~PROMPT
        あなたは漢文（文言文）の専門家です。
        骨格の語順・構造マーカーを保持したまま、語彙を漢字に置換してください。

        【骨格に含まれるマーカー（そのまま保持）】#{marker_note}
        【置換対象】名詞・動詞・形容詞（日本語原形 → 漢字1〜2字）
        【厳守】骨格に準拠した漢字のみ使用すること
        【出力形式】白文のみ・空白なし・1行

        #{HAKUBUN_RULES}
        原文：#{original}
        骨格：#{skeleton}
        白文：
      PROMPT
    else
      <<~PROMPT
        以下の現代日本語を漢文の白文に変換してください。
        出力は白文のみ・空白なし・1行。

        #{HAKUBUN_RULES}
        原文：#{original}
        白文：
      PROMPT
    end
  end

  # ---------------------------------------------------------
  # Ollama 呼び出し
  # ---------------------------------------------------------
  def call_ollama(prompt)
    uri  = URI(OLLAMA_URL)
    body = {
      model:   OLLAMA_MODEL,
      prompt:  prompt,
      stream:  false,
      think:   false,
      options: { temperature: 0.0, num_predict: 200 }
    }.to_json

    response = Net::HTTP.post(uri, body, "Content-Type" => "application/json")
    JSON.parse(response.body)["response"].strip
  end
end
end # module KanbunKa
