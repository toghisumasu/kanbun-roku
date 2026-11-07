# frozen_string_literal: true
# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の lib/kanbun/aozora.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# 漢文注記記法（青空文庫形式の拡張）の字句解析。
#
# 記法の定義は kanbun-javascript（MIT License）の README / kanbun.js に従う。
# 謝辞とライセンスは ACKNOWLEDGMENTS.md と LICENSES/ を参照。
#
#   漢文単位 := 漢字単位 読み仮名? 送り仮名? 再読仮名? 再読送り? 竪点? 訓点?
#
# 例: 未《いま》ダ〈ざ〉ル［＃レ］
#   → kanji "未", yomi 《いま》, okuri "ダ", saidoku 〈ざ〉, saidoku_okuri "ル", kunten "レ"
#
# COBOL の固定長レコードに近く、1 文字ごとに 1 レコード（Unit）を作る。
# 構文が正規文法なので Racc は使わず StringScanner で足りる。

require 'strscan'

module KanbunKa
module Kanbun
  module Aozora
    class ParseError < StandardError; end

    # 読み仮名。hidden=true は〈…〉（漢文では非表示、書き下しでは読みのみ表示）。
    # 置き字は hidden かつ text が空（〈〉）で表す。
    Reading = Struct.new(:text, :hidden) do
      def hidden? = hidden
    end

    # 漢文単位 1 件。
    #   okuri, saidoku_okuri は文字列（なければ ""）
    #   yomi, saidoku は Reading か nil
    #   kunten は "レ" "二" "一レ" "甲レ" など。なければ nil
    Unit = Struct.new(:kanji, :yomi, :okuri, :saidoku, :saidoku_okuri, :tate, :kunten,
                      keyword_init: true) do
      def saidoku? = !saidoku.nil?
      def tate? = tate
      def ren? = !kunten.nil? && kunten.include?('レ')

      # 一レ・甲レ などから順序点だけを取り出す。なければ nil。
      def order_mark = kunten && kunten[Aozora::ORDER_MARK]

      # 再読文字の二度目の読み。読み・送り仮名を再読側に差し替えた複製を返す。
      def second_reading
        copy = dup
        copy.yomi = saidoku
        copy.okuri = saidoku_okuri
        copy.saidoku = nil
        copy.saidoku_okuri = ''
        copy
      end
    end

    ORDER_MARK = /[一二三四上中下天地人甲乙丙丁]/

    # 異体字選択子 U+E0100..U+E01EF を伴ってもよい。
    # \p{Han} は BMP の CJK、互換漢字、拡張 B 以降（サロゲートペア相当）を含む。
    KANJI      = /\p{Han}[\u{E0100}-\u{E01EF}]?/
    KUTOUTEN   = /[。、]/
    KANJI_UNIT = /#{KANJI}|#{KUTOUTEN}/
    KANA       = /[ぁ-ヿ]/
    KANA_KANJI = /#{KANA}|#{KANJI_UNIT}/

    HYOUJI     = /《(#{KANA_KANJI}*)》/
    HIHYOUJI   = /〈(#{KANA_KANJI}*)〉/
    OKURI_RUN  = /#{KANA}+/
    OKURI_BRKT = /［＃（(#{KANA_KANJI}+)）］/
    # 竪点は kanbun.js では U+2010。ASCII のハイフンも受ける。
    TATE       = /[‐-]/
    KUNTEN     = /［＃(#{ORDER_MARK}|[一上天甲]?レ)］/

    module_function

    # テキストを Unit の配列に変換する。改行は無視する（README の折り返し対策）。
    def parse(text)
      ss = StringScanner.new(text.delete("\r\n"))
      units = []
      until ss.eos?
        start = ss.charpos # pos はバイト位置なので、日本語では charpos を使う
        kanji = ss.scan(KANJI_UNIT)
        raise ParseError, error_message(ss, start) unless kanji

        units << Unit.new(
          kanji: kanji,
          yomi: scan_reading(ss),
          okuri: scan_okuri(ss),
          saidoku: scan_reading(ss),
          saidoku_okuri: scan_okuri(ss),
          tate: !ss.scan(TATE).nil?,
          kunten: (ss.scan(KUNTEN) ? ss[1] : nil)
        )
      end
      units
    end

    # 白文（原漢文）。漢字と句読点だけを並べる。
    def hakubun(units, punctuation: true)
      units = parse(units) if units.is_a?(String)
      units.map(&:kanji).reject { |k| !punctuation && k.match?(KUTOUTEN) }.join
    end

    def scan_reading(ss)
      if ss.scan(HYOUJI) then Reading.new(ss[1], false)
      elsif ss.scan(HIHYOUJI) then Reading.new(ss[1], true)
      end
    end

    def scan_okuri(ss)
      if ss.scan(OKURI_RUN) then ss.matched
      elsif ss.scan(OKURI_BRKT) then ss[1]
      else ''
      end
    end

    def error_message(ss, start)
      rest = ss.string[start, 12]
      "漢文単位を読み取れません（#{start + 1} 文字目付近: #{rest.inspect}）"
    end
    private_class_method :scan_reading, :scan_okuri, :error_message
  end
end
end # module KanbunKa
