# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の app/services/skeleton_builder.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# app/services/skeleton_builder.rb
#
# 役割: ParseResult → 漢文白文骨格を生成する
# 出力: 語順が漢文順・構造マーカーは漢字・語彙は日本語原形のまま
# LLMは「語彙の漢字置換のみ」を担う（語順変更は不要）

module KanbunKa
class SkeletonBuilder
  PARTICLE_TYPES = %i[wa ga wo ni yori de to dake kara].freeze

  def self.call(result)
    new(result).build
  end

  def initialize(result)
    @r = result
  end

  def build
    parts = case @r.sentence_type
            when :existential  then build_existential
            when :adjectival   then build_adjectival
            when :sequential   then build_sequential
            when :comparative  then build_comparative
            when :conditional  then build_conditional
            else                    build_verbal     # :transitive / :intransitive
            end
    parts << sentence_end_marker
    parts.compact.reject { |p| p.to_s.empty? }.join(" ").strip
  end

  private

  # 有/無 + 存在物 [+ 於 + 場所]
  # 足がない → "無 足"  /  蛇に足がある → "有 足 於 蛇"
  def build_existential
    cop      = @r.negated ? "無" : "有"
    existent = nouns_only(@r.object)
    location = nouns_only(@r.subject)
    parts    = [cop, existent]
    parts   += ["於", location] if location
    parts
  end

  # 主語 [+ 不] + 述語
  # 馬は速くない → "馬 不 速い"
  # 限定: ただ人だけが … → 主語の前に 惟（Phase 4n）
  def build_adjectival
    [subject_text, ("不" if @r.negated), @r.predicate.base_form]
  end

  # 主語 + V1 + V2 + ... + 目的語  （連動文は動詞を並べる）
  # 王は民を集めて号令した → "王 集める 号令する 民"
  #
  # 共同・場所があるときは動詞ごとに目的語を付ける（Phase 4n）
  #   友と酒を飲んで語る → "与 友 飲む 酒 而 語る"
  def build_sequential
    chain = (@r.chain || []).map(&:base_form)
    if @r.comitative || @r.locative || @r.origin
      parts = [subject_text, *comitative_parts, *origin_parts, chain.first, nouns_only(@r.object), *locative_parts]
      chain.drop(1).each { |verb| parts += ["而", verb] }
      return parts
    end

    [subject_text, *chain, nouns_only(@r.object)]
  end

  # 比較（Phase 4k で肯定の形を直した）
  #   肯定: 主語 + 述語 + 於 + 比較基準
  #     馬は牛より速い → "馬 速い 於 牛"（漢文では 馬速於牛。莫如 は「〜に如くは莫し」で別の句法）
  #   否定: 主語 + 不若 + 比較基準 + 述語
  #     地は人より優れない → "地 不若 人 優れる"
  def build_comparative
    subject = nouns_only(@r.subject)
    standard = nouns_only(@r.object)
    if @r.negated
      [subject, "不若", standard, @r.predicate.base_form]
    else
      [subject, @r.predicate.base_form, "於", standard]
    end
  end

  # 仮定: 条件 + 則 + 帰結（Phase 4s）
  #   学ばなければ道を知らない → "不 学ぶ 則 不 知る 道"
  def build_conditional
    [self.class.call(@r.condition), "則", self.class.call(@r.main)]
  end

  # 動詞文: 使役・受身・通常の3パターンで語順が変わる
  def build_verbal
    if @r.causative
      # 使構文: 主語 使 目的語 [不] 述語
      # 王は人を行かせた → "王 使 人 行く"
      [
        nouns_only(@r.subject), "使",
        nouns_only(@r.object), ("不" if @r.negated),
        @r.predicate.base_form
      ]
    elsif @r.passive
      # 被構文: 主語 被 述語 [於 動作主]
      # 王が臣下に殺された → "王 被 殺す 於 臣下"
      parts = [nouns_only(@r.subject), "被", @r.predicate.base_form]
      parts += ["於", nouns_only(@r.indirect)] if nouns_only(@r.indirect)
      parts
    else
      # 通常: 主語 [不] 述語 目的語 [於 間接]
      #   兄は海で魚を釣る → "兄 釣る 魚 於 海"、友と酒を飲む → "与 友 飲む 酒"（Phase 4n）
      #   彼は鹿児島から来る → "彼 自 鹿児島 来る"、閃光を望見できる → "… 能 望見する 閃光"（Phase 4x）
      parts = [
        subject_text, *comitative_parts, *origin_parts, ("不" if @r.negated),
        ("能" if @r.potential),
        @r.predicate.base_form, nouns_only(@r.object), *locative_parts
      ]
      parts += ["於", nouns_only(@r.indirect)] if nouns_only(@r.indirect)
      parts
    end
  end

  # 文末マーカー（優先順位: 疑問 > 過去）
  def sentence_end_marker
    return "乎" if @r.question
    return "矣" if @r.past
    nil
  end

  # 主語。限定（だけ）なら 惟 を前に付ける
  def subject_text
    subject = nouns_only(@r.subject)
    @r.limited && subject ? "惟 #{subject}" : subject
  end

  # 主語の直後に置く「与 友」。共同がなければ空
  def comitative_parts
    who = nouns_only(@r.comitative)
    who ? ["与", who] : []
  end

  # 起点「自 X」。起点がなければ空（Phase 4x）
  def origin_parts
    from = nouns_only(@r.origin)
    from ? ["自", from] : []
  end

  # 述語・目的語のあとに置く「於 場所」。場所がなければ空
  def locative_parts
    place = nouns_only(@r.locative)
    place ? ["於", place] : []
  end

  def nouns_only(tokens)
    return nil unless tokens
    result = tokens.reject { |t| PARTICLE_TYPES.include?(t.pos_type) }
                   .map(&:base_form).join
    result.empty? ? nil : result
  end
end
end # module KanbunKa
