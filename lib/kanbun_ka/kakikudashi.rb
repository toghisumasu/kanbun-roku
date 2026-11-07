# frozen_string_literal: true
# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の lib/kanbun/kakikudashi.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# 漢文注記記法のテキストから書き下し文を作る。
#
# 読み順の並べ替え（Kanbun::Reorder）の考え方は kanbun-javascript
# （MIT License）に学んでいる。謝辞は ACKNOWLEDGMENTS.md を参照。

require_relative 'aozora'
require_relative 'reorder'

module KanbunKa
module Kanbun
  module Kakikudashi
    module_function

    # text: 注記つき漢文（String）または Aozora.parse の結果
    # yomi:     表示読み《…》を「漢字《よみ》」の形で残すか
    # hiragana: 送り仮名などのカタカナを平仮名にするか
    #
    # 〈…〉の読み（非表示読み）は、書き下しでは漢字の代わりに読みだけを出す。
    # 置き字（空の〈〉）は何も出さない。
    def convert(text, yomi: true, hiragana: false)
      units = text.is_a?(String) ? Aozora.parse(text) : text
      result = Reorder.reorder(units).map { |u| render(u, yomi) + u.okuri }.join
      hiragana ? to_hiragana(result) : result
    end

    def render(unit, show_yomi)
      reading = unit.yomi
      return unit.kanji if reading.nil?
      return reading.text if reading.hidden?
      return unit.kanji if !show_yomi || reading.text.empty?

      "#{unit.kanji}《#{reading.text}》"
    end

    def to_hiragana(text)
      text.tr('ァ-ヶ', 'ぁ-ゖ')
    end

    private_class_method :render
  end
end
end # module KanbunKa
