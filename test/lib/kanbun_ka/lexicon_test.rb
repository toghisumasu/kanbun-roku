require "test_helper"
require Rails.root.join("lib/kanbun_ka/kanbun_parser.tab").to_s

# 複製元（kanbun-ka、コミット 65bb176）の spec/lib/kanbun/lexicon_spec.rb を minitest に移したもの。
class KanbunKa::LexiconTest < ActiveSupport::TestCase
  Lexicon = KanbunKa::Kanbun::Lexicon

  # 意図して複数品詞に登録している表層形（増やすときはここに理由を書く）。言: VERB（言う）と NOUN（ことば）。VERB 優先
  INTENDED_OVERLAPS = %w[ 言 ].freeze

  test "意図しない重複登録がない" do
    assert_equal INTENDED_OVERLAPS, Lexicon.overlaps
  end

  test "全トークンが文法（token 宣言）に存在する" do
    known = KanbunKa::KanbunParser::Racc_token_to_s_table
    missing = Lexicon::TABLE.values.uniq.reject { |t| known.include?(t.to_s) }
    assert_empty missing
  end

  test "複数字語は PATTERN で長い順に先に当たる" do
    assert_equal "深林", "深林"[Lexicon::PATTERN]
    assert_equal "不亦", "不亦"[Lexicon::PATTERN]
  end

  test "言 は VERB に解決される" do
    assert_equal :VERB, Lexicon::TABLE["言"]
  end

  test "再読文字は全て読みの表 SAIDOKU を持つ" do
    saidoku_words = Lexicon::FUNCTION_WORDS.select { |_, t| t == :SAIDOKU }.keys
    assert_equal Lexicon::SAIDOKU.keys.sort, saidoku_words.sort
    assert_equal 8, saidoku_words.size
  end

  test "複製したコードは名前空間 KanbunKa の中だけにある（グローバルな Kanbun・KanbunParser を作らない）" do
    assert_not defined?(::Kanbun)
    assert_not defined?(::KanbunParser)
  end
end
