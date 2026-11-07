# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の app/services/kanbun_parser_service.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。
# 変更点: require のパスを lib/kanbun/ → lib/kanbun_ka/ に変えた。

# app/services/kanbun_parser_service.rb
#
# 役割: 漢文白文 → 訓点付き漢文・書き下し文を生成する
# 実装: Racc パーサー（lib/kanbun/kanbun_parser.tab.rb）で構文木を作り、
#       Kanbun::Kunten で返り点を付け、Kanbun::Kakikudashi で書き下す。
#
#   白文 → KanbunParser#parse_tree → Kanbun::Kunten.annotate → 返り点つき単位列
#        → to_bracket（訓点付き漢文）/ to_aozora（注記つき漢文＝正本）/ Kakikudashi.convert（書き下し）
#
# 解析できない入力（辞書にない字・文法外の語順・返り点を決められない構文）は例外にせず、
# 白文をそのまま返し、status: :unparsed と理由を添える。LLM が書いた白文は
# 辞書の外に出ることが多いので、上流（KanbunTranslatorService）が止まらないようにするため。
#
# 書き下しは返り点で並べ替えた順序と再読文字の読みまで。動詞の活用に応じた送り仮名は
# まだ付かない（Phase 5 の送り仮名辞書）ので、kakikudashi は暫定の書き下しである。
#
# lib/kanbun は Zeitwerk の対象外（生成ファイル kanbun_parser.tab.rb のため）。require で読む。
require Rails.root.join("lib/kanbun_ka/kanbun_parser.tab").to_s
require Rails.root.join("lib/kanbun_ka/kunten").to_s
require Rails.root.join("lib/kanbun_ka/kakikudashi").to_s

module KanbunKa
class KanbunParserService
  # 返り値
  #   kunten:        訓点付き漢文（返り点を [ ] で付記。例: 我読[二]漢文[一]）
  #   kakikudashi:   書き下し文（平仮名。送り仮名は未付与）
  #   kunten_aozora: 注記つき漢文（正本。Kanbun::Aozora.parse で読み戻せる）
  #   status:        :parsed または :unparsed
  #   error:         nil または解析できなかった理由（文字列）
  def self.call(hakubun)
    new(hakubun).call
  end

  def initialize(hakubun)
    @hakubun = hakubun.to_s.strip
  end

  def call
    tree = KanbunParser.new.parse_tree(@hakubun, strict: true)
    units = Kanbun::Kunten.annotate(tree)
    aozora = Kanbun::Kunten.to_aozora(units)

    {
      kunten:        Kanbun::Kunten.to_bracket(units),
      kakikudashi:   Kanbun::Kakikudashi.convert(aozora, yomi: false, hiragana: true),
      kunten_aozora: aozora,
      status:        :parsed,
      error:         nil
    }
  rescue KanbunParser::UnknownCharacters, Racc::ParseError, Kanbun::Kunten::Error => e
    unparsed(e)
  end

  private

  def unparsed(error)
    {
      kunten:        @hakubun,
      kakikudashi:   @hakubun,
      kunten_aozora: nil,
      status:        :unparsed,
      error:         "#{error.class.name.split('::').last}: #{error.message}"
    }
  end
end
end # module KanbunKa
