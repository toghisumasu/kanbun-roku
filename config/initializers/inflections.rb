# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym "RESTful"
# end

# kanbun-ka から複製したコード（app/services/kanbun_ka/）のファイル名と定数名を合わせる。
# kanbun_bnf_parser.rb → KanbunBNFParser、mecab_adapter.rb → MeCabAdapter。
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "BNF"
  inflect.acronym "MeCab"
end
