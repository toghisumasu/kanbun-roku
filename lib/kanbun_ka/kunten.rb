# frozen_string_literal: true
# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の lib/kanbun/kunten.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# 構文木（Kanbun::Tree）から返り点を決め、注記つき漢文の単位列（Aozora::Unit）を作る。
#
#   白文 → [Racc パーサー] → 構文木 → 【ここ】 → Unit 列 → Reorder → 読む順
#
# 返り点の決め方（HB p.147–148 の考え方を、入れ子の形から機械的に導く）
#
#   Ret(head, block) は「block を読んでから head に返る」。block の中で最後に読む語を L とする。
#   1. L が head の直後の 1 字なら レ点。head に「レ」を付ける。
#        不[レ]待[レ]人 … 不→待→人 と 1 字ずつ返る
#   2. そうでなければ 一二点の系列。L の読みが終わる字（下点）に「一」、head に「二」を付ける。
#        読[二]漢文[一] … 漢文を読み終えた「文」に一、読に二
#      同じ字で読み終わる返りが入れ子になっていれば、一二三…と同じ系列に並べる。
#        不[三]必読[二]漢文[一] … 「文」で 漢文→読→不 の順に解ける
#   3. ある系列が別の系列を内側に含むときは、外側の系列を一段上の点にする。
#        一二点 → 上中下点 → 甲乙丙丁点 → 天地人点
#
# 実装は Aozora / Reorder と同じ記法に合わせてあるので、出力を Reorder に通せば
# 構文木が期待した読み順に戻るかを確かめられる（verify: true で毎回確認する）。
#
# 対応していないもの（Unsupported を送出）:
#   - 1 字に 2 つの順序点が必要になる場合（Aozora の記法は 1 字に順序点 1 つ）
#   - 4 段を超える入れ子、系列が点の数を超える場合

require_relative 'tree'
require_relative 'aozora'
require_relative 'reorder'

module KanbunKa
module Kanbun
  module Kunten
    class Error < StandardError; end
    class Unsupported < Error; end

    # 系列の段 → 点（先頭が下点＝先に読む字、以降が上点＝あとで返って読む語）
    LEVELS = [%w[一 二 三 四], %w[上 中 下], %w[甲 乙 丙 丁], %w[天 地 人]].freeze
    TATE = "‐"

    module_function

    # 構文木 → Array<Aozora::Unit>
    def annotate(tree, verify: true)
      ctx = analyze(tree)
      marks = assign_marks(ctx)
      units = build_units(ctx, marks)
      verify!(units, ctx[:reading]) if verify
      units
    end

    # 単位列 → 読む順に並べた文字列（置字は読まないので除く）
    def reading(units)
      Reorder.reorder(units).reject { |u| silent?(u) }.map(&:kanji).join
    end

    # 返り点を [ ] で付記した表示（例: 不[レ]待[レ]人）
    def to_bracket(units)
      units.map { |u| u.kunten ? "#{u.kanji}[#{u.kunten}]" : u.kanji }.join
    end

    # 注記つき漢文（正本）。Aozora.parse で読み戻せる。
    def to_aozora(units)
      units.map { |u| aozora_unit(u) }.join
    end

    # ---- 以下は内部処理 ----

    # 木を走査して、位置・読む順・返りの種類をまとめる。
    def analyze(tree)
      leaves = []
      rets = []
      walk(tree, leaves, rets)

      pos = {}.compare_by_identity
      cursor = 0
      leaves.each do |leaf|
        len = leaf.surface.each_char.count
        pos[leaf] = [cursor, cursor + len - 1]
        cursor += len
      end

      head_of = {}.compare_by_identity
      rets.each { |r| head_of[r.head] = r }

      reading_leaves = reading_order(tree)
      read_index = {}.compare_by_identity
      reading_leaves.each_with_index { |leaf, i| read_index[leaf] = i }

      last_read = {}.compare_by_identity # Ret → block で最後に読む語
      rets.each { |r| last_read[r] = block_reading(r.block).last }

      { leaves: leaves, rets: rets, pos: pos, head_of: head_of, read_index: read_index,
        last_read: last_read, reading: reading_leaves }
    end

    def walk(node, leaves, rets)
      case node
      when Tree::Leaf then leaves << node
      when Tree::Seq then node.children.each { |c| walk(c, leaves, rets) }
      when Tree::Ret
        rets << node
        walk(node.head, leaves, rets)
        node.block.each { |c| walk(c, leaves, rets) }
      else raise Error, "未知のノード: #{node.class}"
      end
    end

    def reading_order(node)
      case node
      when Tree::Leaf then [node]
      when Tree::Seq then block_reading(node.children)
      when Tree::Ret
        # 再読文字は 1 度目をその位置で読み、2 度目に返って読む
        first = node.head.saidoku? ? [node.head] : []
        first + block_reading(node.block) + [node.head]
      end
    end

    def block_reading(nodes)
      nodes.flat_map { |n| reading_order(n) }
    end

    # 返りの種類を決めて、字の位置 → 順序点 の表を作る。
    def assign_marks(ctx)
      pos = ctx[:pos]
      marks = {}
      chains = {}.compare_by_identity # 下点にあたる語 → その系列の Ret

      ctx[:rets].each do |r|
        lb = ctx[:last_read][r]
        if ren?(r, lb, pos)
          put(marks, pos[r.head].last, 'レ')
        else
          (chains[lower_leaf(r, ctx)] ||= []) << r
        end
      end

      levels = chain_levels(chains, pos)
      chains.each do |lower, heads|
        heads.sort_by! { |r| ctx[:read_index][r.head] }
        set = chain_marks(levels[lower], heads.size)
        put(marks, pos[lower].last, set[0])
        heads.each_with_index { |r, i| put(marks, pos[r.head].last, set[i + 1]) }
      end
      marks
    end

    # head の直後の 1 字を最後に読む → レ点
    def ren?(ret, last_read_leaf, pos)
      first, last = pos[last_read_leaf]
      first == last && first == pos[ret.head].last + 1
    end

    # Ret の block が読み終わる字（下点をつける語）。head であれば、その head の読み終わりへたどる。
    def lower_leaf(ret, ctx)
      leaf = ctx[:last_read][ret]
      while (inner = ctx[:head_of][leaf])
        leaf = ctx[:last_read][inner]
      end
      leaf
    end

    # 系列ごとの段（1〜4）。別の系列を内側に含むなら 1 段上げる。
    def chain_levels(chains, pos)
      spans = {}.compare_by_identity
      chains.each do |lower, heads|
        spans[lower] = [heads.map { |r| pos[r.head].first }.min, pos[lower].last]
      end

      levels = {}.compare_by_identity
      level = lambda do |lower|
        levels[lower] ||= begin
          lo, hi = spans[lower]
          inner = spans.keys.reject { |k| k.equal?(lower) }
                       .select { |k| lo <= spans[k][0] && spans[k][1] <= hi }
          depth = 1 + (inner.map { |k| level.call(k) }.max || 0)
          raise Unsupported, '返り点の入れ子が 4 段を超えます' if depth > LEVELS.size

          depth
        end
      end
      chains.each_key { |lower| level.call(lower) }
      levels
    end

    def chain_marks(level, heads_count)
      set = LEVELS[level - 1]
      if heads_count + 1 > set.size
        raise Unsupported, "#{set.join}点では足りません（#{heads_count + 1} 個の点が必要）"
      end

      set
    end

    def put(marks, index, mark)
      if marks.key?(index)
        raise Unsupported, "同じ字に順序点が 2 つ必要です（#{marks[index]} と #{mark}）"
      end

      marks[index] = mark
    end

    def build_units(ctx, marks)
      cursor = 0
      ctx[:leaves].flat_map do |leaf|
        chars = leaf.surface.each_char.to_a
        movable = ctx[:head_of].key?(leaf)
        chars.each_with_index.map do |ch, i|
          unit_for(leaf, ch, movable && i < chars.size - 1, marks[cursor + i])
        end.tap { cursor += chars.size }
      end
    end

    def unit_for(leaf, char, tate, kunten)
      yomi = leaf.silent? ? Aozora::Reading.new('', true) : nil
      okuri = ''
      saidoku = nil
      saidoku_okuri = ''
      if (r = leaf.saidoku)
        yomi = Aozora::Reading.new(r[:yomi], false)
        okuri = r[:okuri]
        saidoku = Aozora::Reading.new(r[:saidoku], true)
        saidoku_okuri = r[:saidoku_okuri]
      end
      Aozora::Unit.new(kanji: char, yomi: yomi, okuri: okuri, saidoku: saidoku,
                       saidoku_okuri: saidoku_okuri, tate: tate, kunten: kunten)
    end

    # Reorder で読み順に戻し、構文木から期待した読み順と一致するか確かめる。
    def verify!(units, reading_leaves)
      expected = reading_leaves.map(&:surface).join
      actual = Reorder.reorder(units).map(&:kanji).join
      return if actual == expected

      raise Error, "返り点の検算に失敗: 期待 #{expected} / 実際 #{actual}（#{to_bracket(units)}）"
    rescue Reorder::Error => e
      raise Error, "返り点の検算に失敗: #{e.message}（#{to_bracket(units)}）"
    end

    def silent?(unit)
      unit.yomi&.hidden? && unit.yomi.text.empty?
    end

    def aozora_unit(unit)
      out = unit.kanji.dup
      out << reading_text(unit.yomi)
      out << unit.okuri.to_s
      out << reading_text(unit.saidoku)
      out << unit.saidoku_okuri.to_s
      out << TATE if unit.tate?
      out << "［＃#{unit.kunten}］" if unit.kunten
      out
    end

    def reading_text(reading)
      return '' unless reading

      reading.hidden ? "〈#{reading.text}〉" : "《#{reading.text}》"
    end

    private_class_method :analyze, :walk, :reading_order, :block_reading, :assign_marks, :ren?,
                         :lower_leaf, :chain_levels, :chain_marks, :put,
                         :build_units, :unit_for, :verify!, :silent?, :aozora_unit, :reading_text
  end
end
end # module KanbunKa
