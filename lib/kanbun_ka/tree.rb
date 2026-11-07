# frozen_string_literal: true
# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の lib/kanbun/tree.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# 構文木（Phase 4c）。Racc の各規則が文字列連結の代わりにこの木を返す。
#
# 読む順序を決める部品は 2 つだけ。
#   Seq … 子を左から右へそのまま読む（返り点なし）
#   Ret … head（返って読む語）を、block（後ろに続く語句）より後で読む
#         例: 読漢文 → Ret(読, [漢文])  読む順は 漢文→読
#
# 句法（否定・比較・選択…）は Seq と Ret の組み合わせで書ける。
# 返り点の種類（レ・一二・上下・甲乙）は、この木の入れ子の形から
# Kanbun::Kunten が決める。構文（語順）が返り点を決め、
# 送り仮名は辞書（動詞の格情報）が決める、という役割分担である。
#
# COBOL の比喩: Seq は PERFORM の順次実行、Ret は「子の処理を先に PERFORM してから
# 自分の後処理を行う」入れ子のコントロールブレークに近い。

module KanbunKa
module Kanbun
  module Tree
    # 1 語。surface は 1 字以上（深林・見聞のような辞書語は 1 つの Leaf）。
    # silent は置字（於・于・乎）：位置は占めるが読まない。
    # saidoku は再読文字（未・将・当…）の読みの表（Lexicon::SAIDOKU の値）。
    #   1 度目はその位置で、2 度目は Ret の head として返ってから読む。
    class Leaf
      attr_reader :surface, :silent, :saidoku

      def initialize(surface, silent: false, saidoku: nil)
        @surface = surface
        @silent = silent
        @saidoku = saidoku
      end

      def silent? = @silent
      def saidoku? = !@saidoku.nil?
      def to_s = @surface
    end

    # 左から右へそのまま読む列。
    class Seq
      attr_reader :children

      def initialize(children)
        @children = children
      end

      def to_s = @children.map(&:to_s).join
    end

    # head を block より後で読む。head は Leaf（1 字以上）。
    class Ret
      attr_reader :head, :block

      def initialize(head, block)
        @head = head
        @block = block
      end

      def to_s = @head.to_s + @block.map(&:to_s).join
    end
  end
end
end # module KanbunKa
