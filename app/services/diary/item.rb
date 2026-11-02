module Diary
  # A の出力の1項目。heading は見出し、text は本文、quote は引用（空文字のこともある）。
  # chunk_index は、複数の塊の座で、どの塊の出力かを示す（連結のあとも残す）。
  Item = Data.define(:heading, :text, :quote, :chunk_index) do
    def initialize(heading:, text:, quote:, chunk_index: nil) = super
  end
end
