class KanbunParser

# トークン定義（フェーズ1 + 部分否定用トークンを追加）
token NEG_BU NEG_FU NEG_HI NEG_MU NEG_BAKU
      PROHIBIT_NAKA
      HITSZU JOU MATA        # 必・常・復（部分否定用）
      MOKU_NAKU MOKU_SHIKA
      FUSHIKA FUNYUU
      YO_NIMO  NAMU IWA_N_YA
      KATEN_SHIKA KATEN_NYO KATEN_IYA
      KATEN_IEDOMO KATEN_TATOI
      GENTEI_YUI GENTEI_DOKU
      SHI_KO SHI_SAI SHI_JA
      HAN_AI FUKI_MATA
      GI_AN GI_DARE GI_IZURE GI_NANI
      GI_NANSURU GI_NANMOTE GI_IKANI_A GI_IKANI_B
      VERB NOUN

rule
  sentence
    : clause { result = val[0] }

  clause
    : double_neg_clause  { result = val[0] }   # 二重否定（新規）
    | partial_neg_clause { result = val[0] }   # 部分否定（新規）
    | compare_clause     { result = val[0] }
    | select_clause      { result = val[0] }
    | suppress_clause    { result = val[0] }
    | katen_clause       { result = val[0] } 
    | gyaku_katen_clause { result = val[0] }
    | gentei_clause      { result = val[0] }
    | hangi_clause       { result = val[0] }
    | shitsumon_clause   { result = val[0] }
    | gi_adv_clause      { result = val[0] }
    | neg_clause         { result = val[0] }   # 否定（フェーズ1）
    | prohibit_clause    { result = val[0] }   # 禁止（フェーズ1）
    | verb_phrase        { result = val[0] }

  # ---- 二重否定句法（フェーズ2a 新規）----
  # 無非〜：〜でないものはない（全て〜である）
  # 無不〜：〜しないものはない（全て〜する）
  # 非不〜：〜しないのではない（〜しないわけではない）
  double_neg_clause
    : NEG_MU NEG_HI verb_phrase { result = "無非#{val[2]}" }
    | NEG_MU NEG_BU verb_phrase { result = "無不#{val[2]}" }
    | NEG_HI NEG_BU verb_phrase { result = "非不#{val[2]}" }

  # ---- 部分否定句法（フェーズ2a 新規）----
  # 不必〜：必ずしも〜ではない
  # 不常〜：いつも〜とは限らない
  # 不復〜：二度と〜しない
  partial_neg_clause
    : NEG_BU HITSZU verb_phrase { result = "不必#{val[2]}" }
    | NEG_BU JOU    verb_phrase { result = "不常#{val[2]}" }
    | NEG_BU MATA   verb_phrase { result = "不復#{val[2]}" }

  # ---- 否定句法（フェーズ1）----
  neg_clause
    : NEG_BU   verb_phrase { result = "不#{val[1]}" }
    | NEG_FU   verb_phrase { result = "弗#{val[1]}" }
    | NEG_HI   verb_phrase { result = "非#{val[1]}" }
    | NEG_MU   verb_phrase { result = "無#{val[1]}" }
    | NEG_BAKU verb_phrase { result = "莫#{val[1]}" }

  # ---- 禁止句法（フェーズ1）----
  prohibit_clause
    : PROHIBIT_NAKA verb_phrase { result = "勿#{val[1]}" }

  # ---- 動詞句（多義字：VERB+VERB も許容）----
  verb_phrase
    : VERB            { result = val[0] }
    | VERB NOUN       { result = "#{val[0]}#{val[1]}" }
    | VERB VERB       { result = "#{val[0]}#{val[1]}" }
    | NOUN            { result = val[0] }
    | NOUN NOUN       { result = "#{val[0]}#{val[1]}" }

# 比較句法（莫如・莫若・不若・不如）
# 百年之計莫如植樹　→ 百年の計は樹を植えるに如くは莫し
  compare_clause
    : verb_phrase MOKU_NAKU    verb_phrase { result = "#{val[0]}莫如#{val[2]}" }
    | verb_phrase MOKU_SHIKA   verb_phrase { result = "#{val[0]}莫若#{val[2]}" }
    | verb_phrase FUSHIKA      verb_phrase { result = "#{val[0]}不若#{val[2]}" }
    | verb_phrase FUNYUU       verb_phrase { result = "#{val[0]}不如#{val[2]}" }

# 選択句法（与A寧B・寧A無B）
# 喪与易寧戚　→ AせんよりはむしろB
  select_clause
    : YO_NIMO verb_phrase NAMU   verb_phrase { result = "与#{val[1]}寧#{val[3]}" }
    | NAMU    verb_phrase NEG_MU verb_phrase { result = "寧#{val[1]}無#{val[3]}" }

# 抑揚句法（況〜乎）   
# 死馬且買之、況生者乎　→ AすらかつB、いわんやCをや
  suppress_clause
    : verb_phrase IWA_N_YA verb_phrase SHI_KO { result = "#{val[0]}況#{val[2]}乎" }

# 仮定法・前置型（若/如/苟 ＋ 動詞句）
# 若不成　→ もし成らずんば
  katen_clause
    : KATEN_SHIKA     verb_phrase         { result = "若#{val[1]}" }
    | KATEN_SHIKA     NEG_BU verb_phrase  { result = "若不#{val[2]}" }
    | KATEN_NYO       verb_phrase         { result = "如#{val[1]}" }
    | KATEN_NYO       NEG_BU verb_phrase  { result = "如不#{val[2]}" }
    | KATEN_IYA       verb_phrase         { result = "苟#{val[1]}" }
    | KATEN_IYA       NEG_MU verb_phrase  { result = "苟無#{val[2]}" }

# 仮定法・逆接型（〜雖〜 / 〜縦〜）
# 学雖無成　→ たとひ学業成らずとも
  gyaku_katen_clause
    : verb_phrase KATEN_IEDOMO    verb_phrase { result = "#{val[0]}雖#{val[2]}" }
    | verb_phrase KATEN_IEDOMO NEG_MU verb_phrase  { result = "#{val[0]}雖無#{val[3]}" }
    | verb_phrase KATEN_TATOI     verb_phrase { result = "#{val[0]}縦#{val[2]}" }

# 限定句法（惟〜 / 独〜）
# 惟士　→ ただ士のみ
  gentei_clause
    : GENTEI_YUI      verb_phrase { result = "惟#{val[1]}" }
    | GENTEI_DOKU     verb_phrase { result = "独#{val[1]}" }
    | GENTEI_DOKU NOUN VERB NOUN  { result = "独#{val[1]}#{val[2]}#{val[3]}" }
# --- 疑問句法（文末助字） ---
  shitsumon_clause
    : verb_phrase SHI_KO          { result = "#{val[0]}乎" }
    | verb_phrase SHI_JA          { result = "#{val[0]}邪" }
    | verb_phrase YO_NIMO         { result = "#{val[0]}与" }
    ;

# --- 反語句法 ---
  hangi_clause
    : HAN_AI      verb_phrase SHI_SAI  { result = "豈#{val[1]}哉" }
    | FUKI_MATA   verb_phrase SHI_KO   { result = "不亦#{val[1]}乎" }
    | NAMU        verb_phrase SHI_KO   { result = "寧#{val[1]}乎" }
    | GENTEI_DOKU verb_phrase SHI_KO   { result = "独#{val[1]}乎" }
    | GENTEI_DOKU verb_phrase SHI_SAI  { result = "独#{val[1]}哉" }
    ;

# --- 疑問副詞句法 ---
  gi_adv_clause
    : GI_AN      VERB        { result = "安#{val[1]}" }
    | GI_DARE    verb_phrase { result = "誰#{val[1]}" }
    | GI_IZURE   NOUN VERB   { result = "孰#{val[1]}#{val[2]}" }
    | GI_NANSURU verb_phrase { result = "何為#{val[1]}" }
    | GI_NANMOTE verb_phrase { result = "何以#{val[1]}" }
    | GI_IKANI_A verb_phrase { result = "何如#{val[1]}" }
    | GI_IKANI_B verb_phrase { result = "如何#{val[1]}" }
    | GI_NANI    verb_phrase { result = "何#{val[1]}" }
    ;
  end

---- header
require 'strscan'

---- inner

VERBS = %w[学 読 書 見 聞 知 行 来 食 飲 思 言 得 入 出 為 陥 慎 争 賢 有 笑
           植 買 戚 易 施 成 還 去 帰 習 敏 説 在 好]
NOUNS = %w[人 君 臣 子 民 文 道 国 師 天 地 王 士 物 事 土 寒 言 計 馬 船]


def parse(str)
  @tokens = tokenize(str)
  @pos = 0
  do_parse
end

def next_token
  @tokens[@pos].tap { @pos += 1 }
end

def tokenize(str)
  tokens = []
  scanner = StringScanner.new(str)
  until scanner.eos?
    case
# --- 複合トークン（単漢字より必ず前） ---
      when scanner.scan(/不亦/) then tokens << [:FUKI_MATA,  '不亦']
      when scanner.scan(/何為/) then tokens << [:GI_NANSURU, '何為']
      when scanner.scan(/何以/) then tokens << [:GI_NANMOTE, '何以']
      when scanner.scan(/何如/) then tokens << [:GI_IKANI_A, '何如']
      when scanner.scan(/如何/) then tokens << [:GI_IKANI_B, '如何']
      when scanner.scan(/莫如/) then tokens << [:MOKU_NAKU,  '莫如']
      when scanner.scan(/莫若/) then tokens << [:MOKU_SHIKA, '莫若']
      when scanner.scan(/不若/) then tokens << [:FUSHIKA,    '不若']
      when scanner.scan(/不如/) then tokens << [:FUNYUU,     '不如']
      when scanner.scan(/与/)   then tokens << [:YO_NIMO,    '与']
      when scanner.scan(/寧/)   then tokens << [:NAMU,       '寧']
      when scanner.scan(/況/)   then tokens << [:IWA_N_YA,  '況']
      when scanner.scan(/不/)   then tokens << [:NEG_BU,     '不']
      when scanner.scan(/弗/)   then tokens << [:NEG_FU,        '弗']
      when scanner.scan(/非/)   then tokens << [:NEG_HI,        '非']
      when scanner.scan(/無/)   then tokens << [:NEG_MU,        '無']
      when scanner.scan(/莫/)   then tokens << [:NEG_BAKU,      '莫']
      when scanner.scan(/勿/)   then tokens << [:PROHIBIT_NAKA, '勿']
      when scanner.scan(/必/)   then tokens << [:HITSZU,        '必']
      when scanner.scan(/常/)   then tokens << [:JOU,           '常']
      when scanner.scan(/復/)   then tokens << [:MATA,          '復']
      # 仮定
      when scanner.scan(/若/)   then tokens << [:KATEN_SHIKA,   '若']
      when scanner.scan(/如/)   then tokens << [:KATEN_NYO,     '如']
      when scanner.scan(/苟/)   then tokens << [:KATEN_IYA,     '苟']
      when scanner.scan(/雖/)   then tokens << [:KATEN_IEDOMO,  '雖']
      when scanner.scan(/縦/)   then tokens << [:KATEN_TATOI,   '縦']
      # 限定
      when scanner.scan(/惟/)   then tokens << [:GENTEI_YUI,    '惟']
      when scanner.scan(/独/)   then tokens << [:GENTEI_DOKU,   '独']
      when scanner.scan(/豈/)   then tokens << [:HAN_AI,    '豈']
      when scanner.scan(/安/)   then tokens << [:GI_AN,     '安']
      when scanner.scan(/誰/)   then tokens << [:GI_DARE,   '誰']
      when scanner.scan(/孰/)   then tokens << [:GI_IZURE,  '孰']
      when scanner.scan(/何/)   then tokens << [:GI_NANI,   '何']
      when scanner.scan(/乎/)   then tokens << [:SHI_KO,    '乎']
      when scanner.scan(/哉/)   then tokens << [:SHI_SAI,   '哉']
      when scanner.scan(/邪/)   then tokens << [:SHI_JA,    '邪']
      when scanner.scan(Regexp.new("[#{VERBS.join}]")) then tokens << [:VERB, scanner.matched]
      when scanner.scan(Regexp.new("[#{NOUNS.join}]")) then tokens << [:NOUN, scanner.matched]
    else scanner.getch
    end
  end
  tokens << [false, nil]
  tokens
end

---- footer

if __FILE__ == $0
  parser = KanbunParser.new

  tests = [
    # フェーズ1（回帰テスト）
    ["不学",   "不学"],
    ["不読書", "不読書"],
    ["莫笑",   "莫笑"],
    # フェーズ2a：二重否定
    ["無非王土", "無非王土"],   # 王の土地でないものはない
    ["無不陥",   "無不陥"],     # 陥さないものはない
    ["非不慎",   "非不慎"],     # 慎まないのではない
    # フェーズ2a：部分否定
    ["不必賢",   "不必賢"],     # 必ずしも賢いわけではない
    ["不常有",   "不常有"],     # いつもあるとは限らない
    ["不復得",   "不復得"],     # 二度と得られない
    # フェーズ2b：
    ["計莫如植",   "計莫如植"],
    ["地不若人",   "地不若人"],
    ["与易寧戚",   "与易寧戚"],
    ["寧為無為",   "寧為無為"],
    ["馬況人乎",   "馬況人乎"], 
    # フェーズ3a
    ["若不成",     "若不成"],
    ["如不成",     "如不成"],
    ["苟無成",     "苟無成"],
    ["学雖無成",   "学雖無成"],
    ["惟士",       "惟士"],
    ["独臣有船",   "独臣有船"],
    # Phase 3b：疑問
    ["学乎",       "学乎"],
    ["学邪",       "学邪"],
    # Phase 3b：反語
    ["豈学哉",     "豈学哉"],
    ["不亦説乎",   "不亦説乎"],
    ["寧有乎",     "寧有乎"],
    ["独学乎",     "独学乎"],
    # Phase 3b：疑問副詞
    ["安在",       "安在"],
    ["何為行",     "何為行"],
    ["何以知",     "何以知"],
    ["如何行",     "如何行"],
    ["孰臣賢",     "孰臣賢"],
    # 回帰確認
    ["馬況人乎",   "馬況人乎"],
  ]

  tests.each do |input, expected|
    result = parser.parse(input)
    status = result == expected ? "OK" : "NG（期待:#{expected}）"
    puts "#{input} => #{result}  #{status}"
  rescue => e
    puts "#{input} => エラー: #{e.message}"
  end
end

