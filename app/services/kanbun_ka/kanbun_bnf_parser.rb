# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の app/services/kanbun_bnf_parser.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。

# app/services/kanbun_bnf_parser.rb

module KanbunKa
class KanbunBNFParser

  # ---------------------------------------------------------
  # Token・定数
  # ---------------------------------------------------------
  Token = Struct.new(:surface, :pos_type, :base_form, keyword_init: true)

  NOUN     = :noun
  PRON     = :pron
  WA       = :wa
  GA       = :ga
  WO       = :wo
  NI       = :ni
  VERB     = :verb
  ADJ      = :adj
  ADJV     = :adjv
  NEG      = :neg
  ARU      = :aru
  NAI_ADJ  = :nai_adj
  PASSIVE  = :passive
  CAUS     = :causative
  PAST     = :past
  CONJ_TE  = :conj_te
  YORI     = :yori
  QUESTION = :question
  DE       = :de      # 場所の で（→ 於）  Phase 4n
  TO       = :to      # 共同の と（→ 与）  Phase 4n
  DAKE     = :dake    # だけ（→ 惟）       Phase 4n
  BA       = :ba      # 仮定の ば（→ 則）  Phase 4s
  KARA     = :kara    # 起点の から（→ 自）Phase 4x
  POT      = :pot     # 可能の できる（→ 能）Phase 4x
  REASON   = :reason  # 理由の から。どの規則も受け付けず、骨格を作らず LLM に任せる（Phase 4x）

  # ---------------------------------------------------------
  # ParseResult
  # initialize は override しない。
  # 全 ParseResult.new 呼び出しで chain:/question: を明示する。
  # ---------------------------------------------------------
  ParseResult = Struct.new(
    :subject, :object, :indirect, :predicate,
    :chain, :question,
    :negated, :passive, :causative, :past, :sentence_type,
    :locative, :comitative, :limited,
    :condition, :main,
    :origin, :potential,
    keyword_init: true
  ) do
    PARTICLE_TYPES = %i[wa ga wo ni yori de to dake kara].freeze

    def to_kanbun_hint
      parts = case sentence_type
              when :existential
                cop = negated ? "無" : "有"
                [].tap do |p|
                  p << "#{cop}構文"
                  p << "存在物: #{nouns_only(object)}"      if object
                  p << "場所/所有: #{nouns_only(subject)}"  if subject
                end
              when :adjectival
                [].tap do |p|
                  p << "形容詞文"
                  p << "主語: #{nouns_only(subject)}"       if subject
                  p << "#{"不＋" if negated}述語: #{predicate.base_form}"
                end
              when :conditional
                ["仮定: #{condition.to_kanbun_hint}", "帰結: #{main.to_kanbun_hint}"]
              when :sequential
                [].tap do |p|
                  p << "主語: #{nouns_only(subject)}"        if subject
                  p << "連動: #{(chain || []).map(&:base_form).join("→")}"
                  p << "目的語: #{nouns_only(object)}"       if object
                  p << "[過去・完了]"                         if past
                end
              when :comparative
                cop = negated ? "不若（及ばない）" : "莫如（が最良）"
                [].tap do |p|
                  p << "比較文(#{cop})"
                  p << "主語: #{nouns_only(subject)}"        if subject
                  p << "比較基準: #{nouns_only(object)}"
                  p << "#{"不＋" if negated}述語: #{predicate.base_form}"
                end
              else
                [].tap do |p|
                  p << "主語: #{nouns_only(subject)}"               if subject
                  p << "[使役 → 使構文]"                            if causative
                  p << "[受身 → 被構文]"                            if passive
                  p << "起点(→ 自): #{nouns_only(origin)}"          if origin
                  p << "[可能 → 能]"                                 if potential
                  p << "#{"不＋" if negated}述語: #{predicate.base_form}"
                  p << "共同(→ 与): #{nouns_only(comitative)}"      if comitative
                  p << "目的語: #{nouns_only(object)}"              if object
                  p << "場所(→ 於): #{nouns_only(locative)}"        if locative
                  p << "に格（→ 於/給）: #{nouns_only(indirect)}"  if indirect
                  p << "[過去・完了]"                                if past
                end
              end
      parts << "【疑問 → 乎/哉】" if question
      parts.join(" / ")
    end

    private

    def nouns_only(tokens)
      return "" unless tokens
      tokens.reject { |t| PARTICLE_TYPES.include?(t.pos_type) }
            .map(&:surface).join
    end
  end

  # ---------------------------------------------------------
  # コンストラクタ
  # ---------------------------------------------------------
  def initialize(tokens)
    @tokens = tokens
    @idx    = 0
  end

  def parse
    @idx   = 0
    result = sentence_rule
    (result && @idx == @tokens.size) ? result : nil
  end

  private

  # ---------------------------------------------------------
  # コアプリミティブ
  # ---------------------------------------------------------
  def term(*pos_types)
    t = @tokens[@idx]
    return nil unless t && pos_types.include?(t.pos_type)
    @idx += 1
    t
  end

  def seq
    saved  = @idx
    result = yield
    unless result
      @idx = saved
      return nil
    end
    result
  end

  def alt(*rules)
    saved = @idx
    rules.each do |rule|
      @idx = saved
      r    = rule.call
      return r if r
    end
    nil
  end

  def optional(&blk)
    saved  = @idx
    result = blk.call
    @idx   = saved unless result
    result
  end

  # ---------------------------------------------------------
  # 部品ルール
  # ---------------------------------------------------------
  def limited?(subject_tokens)
    !subject_tokens.nil? && subject_tokens.any? { |t| t.pos_type == DAKE }
  end

  def noun_tokens
    ts = []
    while (t = term(NOUN, PRON))
      ts << t
    end
    ts.empty? ? nil : ts
  end

  def subject_phrase
    seq do
      ns = noun_tokens;  break nil unless ns
      m  = term(WA, GA); break nil unless m
      ns + [m]
    end
  end

  # ただ人だけが … の だけ（限定）。subject_phrase に差し込んで使う
  def limited_subject_phrase
    seq do
      ns = noun_tokens;  break nil unless ns
      d  = term(DAKE);   break nil unless d
      m  = term(WA, GA); break nil unless m
      ns + [d, m]
    end
  end

  def locative_phrase
    seq do
      ns = noun_tokens; break nil unless ns
      m  = term(DE);    break nil unless m
      ns + [m]
    end
  end

  def comitative_phrase
    seq do
      ns = noun_tokens; break nil unless ns
      m  = term(TO);    break nil unless m
      ns + [m]
    end
  end

  # 鹿児島から … の から（起点）
  def origin_phrase
    seq do
      ns = noun_tokens; break nil unless ns
      m  = term(KARA);  break nil unless m
      ns + [m]
    end
  end

  def object_phrase
    seq do
      ns = noun_tokens; break nil unless ns
      m  = term(WO);    break nil unless m
      ns + [m]
    end
  end

  def indirect_phrase
    seq do
      ns = noun_tokens; break nil unless ns
      m  = term(NI);    break nil unless m
      ns + [m]
    end
  end

  # ---------------------------------------------------------
  # 文タイプ別ルール
  # ---------------------------------------------------------
  def existential_sentence
    seq do
      owner = optional { indirect_phrase }
      nouns = noun_tokens; break nil unless nouns
      ga    = term(GA);    break nil unless ga

      pred_info = alt(
        -> { seq { t = term(ARU);     break nil unless t; { token: t, negated: false } } },
        -> { seq { t = term(NAI_ADJ); break nil unless t; { token: t, negated: true  } } }
      )
      break nil unless pred_info

      _past = optional { term(PAST) }

      ParseResult.new(
        subject: owner, object: nouns + [ga], indirect: nil,
        predicate: pred_info[:token], negated: pred_info[:negated],
        passive: false, causative: false, past: !!_past,
        chain: nil, question: false,
        sentence_type: :existential
      )
    end
  end

  def adjectival_sentence
    seq do
      subj  = optional { limited_subject_phrase } || optional { subject_phrase }
      pred  = term(ADJ, ADJV); break nil unless pred
      neg   = optional { term(NEG) }
      _past = optional { term(PAST) }

      ParseResult.new(
        subject: subj, object: nil, indirect: nil,
        predicate: pred, negated: !!neg,
        passive: false, causative: false, past: !!_past,
        chain: nil, question: false,
        sentence_type: :adjectival,
        limited: limited?(subj)
      )
    end
  end

  def sequential_sentence
    seq do
      subj  = optional { limited_subject_phrase } || optional { subject_phrase }
      comit = optional { comitative_phrase }
      orig  = optional { origin_phrase }
      loc   = optional { locative_phrase }
      obj   = optional { object_phrase }
      indir = optional { indirect_phrase }

      chain = []
      loop do
        v = term(VERB); break unless v
        chain << v
        te = term(CONJ_TE); break unless te
      end
      break nil if chain.size < 2

      neg   = optional { term(NEG) }
      _past = optional { term(PAST) }

      ParseResult.new(
        subject: subj, object: obj, indirect: indir,
        predicate: chain.last, chain: chain,
        negated: !!neg, passive: false, causative: false,
        past: !!_past, question: false,
        sentence_type: :sequential,
        locative: loc, comitative: comit, limited: limited?(subj), origin: orig
      )
    end
  end

  def comparative_sentence
    seq do
      subj     = optional { subject_phrase }
      standard = noun_tokens; break nil unless standard
      yori     = term(YORI);  break nil unless yori
      pred     = term(ADJ, ADJV, VERB); break nil unless pred
      neg      = optional { term(NEG) }
      _past    = optional { term(PAST) }

      ParseResult.new(
        subject: subj, object: standard + [yori], indirect: nil,
        predicate: pred, negated: !!neg,
        passive: false, causative: false, past: !!_past,
        chain: nil, question: false,
        sentence_type: :comparative
      )
    end
  end

  def verbal_sentence
    seq do
      subj  = optional { limited_subject_phrase } || optional { subject_phrase }
      comit = optional { comitative_phrase }
      orig  = optional { origin_phrase }
      loc   = optional { locative_phrase }
      obj   = optional { object_phrase }
      indir = optional { indirect_phrase }
      pred  = term(VERB); break nil unless pred
      pot   = optional { term(POT) }
      caus  = optional { term(CAUS) }
      pass  = optional { term(PASSIVE) }
      neg   = optional { term(NEG) }
      _past = optional { term(PAST) }

      ParseResult.new(
        subject: subj, object: obj, indirect: indir,
        predicate: pred, negated: !!neg,
        passive: !!pass, causative: !!caus, past: !!_past,
        chain: nil, question: false,
        sentence_type: obj ? :transitive : :intransitive,
        locative: loc, comitative: comit, limited: limited?(subj),
        origin: orig, potential: !!pot
      )
    end
  end

  # 「VなければV」「VすればV」: 未然形・仮定形＋ば のあとに帰結の文が続く（Phase 4s）
  #   学ばなければ道を知らない → 条件(不 学ぶ) 則 帰結(不 知る 道)
  def conditional_antecedent
    seq do
      subj  = optional { limited_subject_phrase } || optional { subject_phrase }
      obj   = optional { object_phrase }
      indir = optional { indirect_phrase }
      pred  = term(VERB); break nil unless pred
      neg   = optional { term(NEG) }
      ba    = term(BA);   break nil unless ba

      ParseResult.new(
        subject: subj, object: obj, indirect: indir,
        predicate: pred, negated: !!neg,
        passive: false, causative: false, past: false,
        chain: nil, question: false,
        sentence_type: obj ? :transitive : :intransitive
      )
    end
  end

  def conditional_sentence
    seq do
      cond = conditional_antecedent; break nil unless cond
      main = alt(
        -> { existential_sentence },
        -> { adjectival_sentence },
        -> { sequential_sentence },
        -> { comparative_sentence },
        -> { verbal_sentence }
      )
      break nil unless main

      ParseResult.new(
        subject: nil, object: nil, indirect: nil,
        predicate: main.predicate, negated: false,
        passive: false, causative: false, past: false,
        chain: nil, question: false,
        sentence_type: :conditional, condition: cond, main: main
      )
    end
  end

  def sentence_rule
    r = alt(
      -> { conditional_sentence },
      -> { existential_sentence },
      -> { adjectival_sentence },
      -> { sequential_sentence },
      -> { comparative_sentence },
      -> { verbal_sentence }
    )
    return nil unless r

    q = optional { term(QUESTION) }
    r.question = !q.nil?
    r
  end
end
end # module KanbunKa
