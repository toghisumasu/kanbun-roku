# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の app/services/mecab_adapter.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。

# app/services/mecab_adapter.rb
#
# MeCab（IPA辞書）出力 → KanbunBNFParser::Token配列 変換

module KanbunKa
class MeCabAdapter
  # フィールドインデックス（IPA辞書）
  F_POS   = 0   # 品詞
  F_SUB1  = 1   # 品詞細分類1
  F_BASE  = 6   # 原形

  # 「AとB」の「と」は MeCab では並立助詞で、共同（友と飲む）と並列（りんごとみかん）を区別できない。
  # 直前が人を表す語のときだけ共同（TO）とみなし、それ以外は従来どおり捨てる（Phase 4n）。
  PERSON_NOUNS = %w[友 友人 仲間 兄 弟 姉 妹 父 母 子 妻 夫 親 孫 先生 師 君 彼 彼女 客 隣人].freeze

  # mecab_adapter.rb の call メソッドを修正
  def self.call(mecab_output)
    raw = mecab_output.split("\n")
              .reject { |l| l.start_with?("EOS") || l.strip.empty? }
              .filter_map { |l| build_token(l) }
    raw = resolve_to(raw)             # ⓪ と を共同(TO)にするか捨てるか決める
    raw = merge_dekiru(raw)           # ⓪' できる を可能(POT)に整える（Phase 4x）
    raw = merge_shimau_pattern(raw)   # ① てしまう を除去
    raw = merge_suru_verbs(raw)       # ② サ変動詞を統合
    merge_compound_verbs(raw)         # ③ 複合動詞を統合
  end

  # ⓪ 「と」: 直前が人を表す名詞・代名詞なら共同(TO)、それ以外は捨てる
  private_class_method def self.resolve_to(tokens)
    result = []
    tokens.each do |t|
      if t.pos_type == KanbunBNFParser::TO
        prev = result.last
        person = prev && [KanbunBNFParser::NOUN, KanbunBNFParser::PRON].include?(prev.pos_type) &&
                 PERSON_NOUNS.include?(prev.base_form)
        result << t if person
      else
        result << t
      end
    end
    result
  end

  # ⓪' 可能の「できる」（Phase 4x）
  #   望見できる   → VERB(望見) + POT（する は付けない。LLM が 望見→望 と縮めにくくなる）
  #   泳ぐことができる → VERB(泳ぐ) + POT（こと・が を除く）
  #   それ以外（「勉強ができる」など）は POT を残し、BNF が通らず LLM に任せる
  private_class_method def self.merge_dekiru(tokens)
    result = []
    tokens.each do |t|
      if t.pos_type == KanbunBNFParser::POT
        prev = result.last
        if prev&.pos_type == KanbunBNFParser::GA &&
           result[-2]&.pos_type == KanbunBNFParser::NOUN && result[-2].base_form == "こと" &&
           result[-3]&.pos_type == KanbunBNFParser::VERB
          result.pop(2)                       # が・こと を除く
        elsif prev&.pos_type == KanbunBNFParser::NOUN && prev.base_form != "こと"
          result[-1] = KanbunBNFParser::Token.new(
            surface:   prev.surface,
            pos_type:  KanbunBNFParser::VERB,
            base_form: prev.base_form
          )
        end
      end
      result << t
    end
    result
  end

  # ① て + しまう → 両方除去（完了は直後のたが担う）
  private_class_method def self.merge_shimau_pattern(tokens)
    result = []
    i = 0
    while i < tokens.size
      t      = tokens[i]
      next_t = tokens[i + 1]
      if t.pos_type == KanbunBNFParser::CONJ_TE &&
         next_t&.pos_type == KanbunBNFParser::VERB &&
         next_t&.base_form == "しまう"
        i += 2  # te + shimau をスキップ
      else
        result << t
        i += 1
      end
    end
    result
  end

  # ③ 連続するVERBを複合動詞として統合
  private_class_method def self.merge_compound_verbs(tokens)
    result = []
    i = 0
    while i < tokens.size
      t      = tokens[i]
      next_t = tokens[i + 1]
      if t.pos_type == KanbunBNFParser::VERB &&
         next_t&.pos_type == KanbunBNFParser::VERB
        merged = KanbunBNFParser::Token.new(
          surface:   t.surface + next_t.surface,
          pos_type:  KanbunBNFParser::VERB,
          base_form: next_t.base_form   # 後の動詞を基本形として使用
        )
        result << merged
        i += 2
      else
        result << t
        i += 1
      end
    end
    result
  end

  # 「名詞-サ変接続」+「する/した/し+助動詞」→ 単一VERBに統合
  private_class_method def self.merge_suru_verbs(tokens)
    result = []
    i = 0
    while i < tokens.size
      t = tokens[i]
      # サ変接続名詞の次がsuru動詞なら結合
      if t.pos_type == KanbunBNFParser::NOUN &&
         tokens[i + 1]&.pos_type == KanbunBNFParser::VERB &&
         %w[する くる].include?(tokens[i + 1].base_form)

        merged = KanbunBNFParser::Token.new(
          surface:   t.surface + tokens[i + 1].surface,
          pos_type:  KanbunBNFParser::VERB,
         base_form: t.base_form + "する"
        )
        result << merged
        i += 2
      else
        result << t
        i += 1
      end
    end
    result
  end

  private_class_method def self.build_token(line)
    surface, feat_str = line.split("\t", 2)
    return nil unless feat_str

    f       = feat_str.split(",")
    pos     = f[F_POS]
    sub1    = f[F_SUB1]
    base    = f[F_BASE] || surface
    pos_type = classify(pos, sub1, base, surface)
    return nil unless pos_type   # 助詞「の」「と」など未対応品詞はスキップ

    KanbunBNFParser::Token.new(surface: surface, pos_type: pos_type, base_form: base)
  end

  private_class_method def self.classify(pos, sub1, base, surface)
    case pos
    when "名詞"
      case sub1
      when "代名詞"        then KanbunBNFParser::PRON
      when "形容動詞語幹"  then KanbunBNFParser::ADJV
      else                      KanbunBNFParser::NOUN
      end
    when "助詞"
      case surface
      when "は"        then KanbunBNFParser::WA
      when "が"        then KanbunBNFParser::GA
      when "を"        then KanbunBNFParser::WO
      when "に"        then KanbunBNFParser::NI
      when "より"      then KanbunBNFParser::YORI
      when "から"
        # 起点の から（格助詞）→ KARA。理由の から（接続助詞）は REASON にして骨格を作らない（Phase 4x）
        sub1 == "格助詞" ? KanbunBNFParser::KARA : KanbunBNFParser::REASON
      when "て"
        sub1 == "接続助詞" ? KanbunBNFParser::CONJ_TE : nil
      when "で"
        # 飲んで・読んで の で は接続助詞（て と同じ）。場所の で は格助詞（Phase 4n）
        case sub1
        when "接続助詞" then KanbunBNFParser::CONJ_TE
        when "格助詞"   then KanbunBNFParser::DE
        end
      when "と"
        KanbunBNFParser::TO   # 共同かどうかは resolve_to で決める
      when "だけ"
        KanbunBNFParser::DAKE
      when "ば"
        # 仮定の ば（学ばなければ・学べば）。なければ の なけれ は助動詞 ない(NEG) で拾われる（Phase 4s）
        sub1 == "接続助詞" ? KanbunBNFParser::BA : nil
      when "か", "や"
        # か は「副助詞／並立助詞／終助詞」という長い品詞細分類で出る（Phase 4n）
        sub1.to_s.include?("終助詞") ? KanbunBNFParser::QUESTION : nil
      end
    when "動詞"
      if    %w[ある いる].include?(base) then KanbunBNFParser::ARU
      elsif base == "できる"             then KanbunBNFParser::POT   # 可能（Phase 4x）
      else                                    KanbunBNFParser::VERB
      end
    when "形容詞"
      base == "ない" ? KanbunBNFParser::NAI_ADJ : KanbunBNFParser::ADJ
    when "助動詞"
      case base
      when "ない", "ぬ", "ず"  then KanbunBNFParser::NEG
      when "れる", "られる"    then KanbunBNFParser::PASSIVE
      when "せる", "させる"    then KanbunBNFParser::CAUS
      when "た", "だ"          then KanbunBNFParser::PAST
      end
    end
  end
end
end # module KanbunKa
