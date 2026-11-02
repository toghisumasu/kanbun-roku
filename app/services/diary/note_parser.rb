require "json"

module Diary
  # Ollama が返した A の出力（JSON の文字列）を、見出しごとの Diary::Item の配列にする。DBには触れない。
  # スキーマで構造は固定してあるが、崩れた出力・長さで打ち切られた出力も、そのまま残して調べられるよう、
  # ここで改めて検査する。見出しの欠落、配列でないもの、本文・引用が文字列でない項目、件数が上限を超えるものは、
  # ParseError にする。
  module NoteParser
    class ParseError < StandardError
      attr_reader :kind # :invalid_json / :schema

      def initialize(kind, message)
        @kind = kind
        super(message)
      end
    end

    class << self
      def call(content, chunk_index: nil)
        data = parse_json(content)
        raise ParseError.new(:schema, "JSON の最上位がオブジェクトではありません") unless data.is_a?(Hash)

        Rules::HEADINGS.to_h { |heading| [ heading, items_for(heading, data[heading], chunk_index) ] }
      end

      private

      def parse_json(content)
        JSON.parse(content.to_s)
      rescue JSON::ParserError
        raise ParseError.new(:invalid_json, "JSON として解析できません")
      end

      def items_for(heading, list, chunk_index)
        raise ParseError.new(:schema, "見出し「#{heading}」が配列ではありません") unless list.is_a?(Array)
        raise ParseError.new(:schema, "見出し「#{heading}」の件数が上限を超えています") if list.size > Rules::MAX_ITEMS.fetch(heading)

        list.map do |raw|
          unless raw.is_a?(Hash) && raw["本文"].is_a?(String) && raw["引用"].is_a?(String)
            raise ParseError.new(:schema, "見出し「#{heading}」に、本文・引用が文字列でない項目があります")
          end

          Item.new(heading:, text: raw["本文"], quote: raw["引用"], chunk_index:)
        end
      end
    end
  end
end
