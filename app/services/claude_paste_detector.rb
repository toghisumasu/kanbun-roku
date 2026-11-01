# 人間の発言が、Claude（assistant）の文の貼り付けかを判定する。DBには触れない純粋なクラス。
#
# 一致した部分だけを置き換えるため、正規化は「正規化後の i 文字目が、元の文のどこ（文字位置）から来たか」の
# 対応表を持てる（normalize_with_map）。NFKC は文字の並びで結果が変わる（半角カナ＋濁点など）ので、
# 書記素クラスタごとに行い、正規化後の1文字は元のクラスタ1つに対応づける。
#
# 判定: 発言と、与えられた assistant の本文のどれかとの最長の連続一致が MIN_CHARS 字以上なら、貼り付けとする。
# 発言全体に占める割合は問わない（一致した部分だけを置き換えるので、残りは元のまま使える）。
# 正規化は NFKC のあと、空白・句読点・記号を除く。
#
# 照合の対象は、before: に渡した時刻より前の assistant メッセージだけ（その時刻以降のものは使わない）。
# before: を省くと、渡した assistant メッセージすべてが対象になる。
#
# assistant の本文は初期化のときに渡す（全会話ぶん）。要素は文字列、または body / occurred_at に答えるもの。
# 文字列には時刻がないので、before: を指定してもつねに対象になる。MIN_CHARS 字の窓を全位置で索引にするので、
# 本文の総量に比例してメモリを使う（実データ約720万字で数百MB）。
class ClaudePasteDetector
  MIN_CHARS = 50
  STRIP = /[[:space:]\p{P}\p{S}]/

  def self.normalize(text) = normalize_with_map(text).first

  # [正規化後の文字列, 対応表]。対応表の i 番目は、正規化後の i 文字目を作った元のクラスタの [開始, 終了)（元の文字位置）。
  def self.normalize_with_map(text)
    text = text.to_s
    out = +""
    map = []
    offset = 0
    text.each_grapheme_cluster do |cluster|
      kept = cluster.unicode_normalize(:nfkc).gsub(STRIP, "")
      kept.each_char do |char|
        out << char
        map << [ offset, offset + cluster.size ]
      end
      offset += cluster.size
    end
    [ out, map ]
  end

  def initialize(assistant_messages, min_chars: MIN_CHARS)
    @min_chars = min_chars
    pairs = assistant_messages.map do |m|
      m.is_a?(String) ? [ self.class.normalize(m), nil ] : [ self.class.normalize(m.body), m.occurred_at ]
    end.reject { |text, _| text.size < min_chars }
    @texts = pairs.map(&:first)
    @times = pairs.map(&:last)
    @index = {}
    @texts.each_with_index do |text, text_index|
      (0..text.size - min_chars).each do |pos|
        key = text[pos, min_chars].hash
        packed = (text_index << 24) | pos
        current = @index[key]
        @index[key] = current.nil? ? packed : (current.is_a?(Array) ? current << packed : [ current, packed ])
      end
    end
  end

  # 最長の連続一致の長さ（MIN_CHARS 未満なら 0）。stop_at 以上が見つかった時点で打ち切る。
  def longest_match(body, stop_at: nil, before: nil)
    u = self.class.normalize(body)
    best = 0
    i = 0
    while i <= u.size - @min_chars && u.size - i > best
      best = [ best, longest_match_at(u, i, before) ].max
      return best if stop_at && best >= stop_at
      i += 1
    end
    best
  end

  # 元の文での置き換え範囲（from...to、文字位置）と、その正規化後の長さ。
  Span = Struct.new(:from, :to, :length, keyword_init: true)

  # MIN_CHARS 字以上一致した部分（連続しているものは1つにまとめる）の、元の文での範囲。前から順に返す。
  # 範囲の直後に続く句読点・記号は、その一致に含める（空白・改行は含めない）。
  def match_spans(body, before: nil)
    u, map = self.class.normalize_with_map(body)
    original = body.to_s
    intervals = []
    i = 0
    while i <= u.size - @min_chars
      length = longest_match_at(u, i, before)
      if length >= @min_chars
        if intervals.last && intervals.last[1] == i
          intervals.last[1] = i + length
        else
          intervals << [ i, i + length ]
        end
        i += length
      else
        i += 1
      end
    end
    intervals.map do |from, to|
      last = map[to - 1][1]
      last += 1 while last < original.size && original[last].match?(/[\p{P}\p{S}]/)
      Span.new(from: map[from][0], to: last, length: to - from)
    end
  end

  # 一致した部分だけを mark に置き換えた文。一致しない部分はそのまま。一致がなければ元の文を返す。
  def mask(body, mark, before: nil)
    text = body.to_s.dup
    match_spans(body, before:).reverse_each { |span| text[span.from...span.to] = mark }
    text
  end

  # 一致部分を除いて残る部分の長さ（正規化後の文字数）。
  def remainder_size(body, before: nil)
    self.class.normalize(body).size - match_spans(body, before:).sum(&:length)
  end

  Analysis = Struct.new(:match_length, :size, :ratio, keyword_init: true)

  # 最長の連続一致の長さ（正規化後の文字数）と、発言全体（正規化後）に占める割合。確認用で、打ち切りはしない。
  def analyze(body, before: nil)
    size = self.class.normalize(body).size
    length = longest_match(body, before:)
    Analysis.new(match_length: length, size:, ratio: size.zero? ? 0.0 : length.fdiv(size))
  end

  def paste?(body, before: nil)
    longest_match(body, stop_at: @min_chars, before:) >= @min_chars
  end

  private

  # 正規化済みの u の i 文字目から始まる、最長の連続一致の長さ（MIN_CHARS 未満なら 0）。
  def longest_match_at(u, i, before = nil)
    found = @index[u[i, @min_chars].hash]
    return 0 unless found

    best = 0
    Array(found).each do |packed|
      time = @times[packed >> 24]
      next if before && time && time >= before

      text = @texts[packed >> 24]
      pos = packed & 0xFFFFFF
      next unless u[i, @min_chars] == text[pos, @min_chars]

      length = @min_chars
      length += 1 while i + length < u.size && pos + length < text.size && u[i + length] == text[pos + length]
      best = length if length > best
    end
    best
  end
end
