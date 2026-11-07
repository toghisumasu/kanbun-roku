# frozen_string_literal: true
# 複製元: https://github.com/toghisumasu/kanbun-ka（コミット 65bb176）の lib/kanbun/reorder.rb。
# kanbun-roku への複製では、名前空間 KanbunKa で包んだ（module KanbunKa ... end を足した）点と、下に記す箇所だけを変えている。


# 返り点つきの漢文単位列を、書き下し（読む）順に並べ替える。
#
# 本ファイルは kanbun-javascript の kanbun.js にある kanbun_reorder の
# 処理手順を Ruby に移植・再構成したものである。
#   https://github.com/kawabata/kanbun-javascript
#
#   Copyright (c) 2019 Teruyuki Kobayashi koba1014@gmail.com
#   Copyright (c) 2018 kawabata
#
# 移植元は MIT License。全文は LICENSES/kanbun-javascript-MIT.txt、
# 謝辞は ACKNOWLEDGMENTS.md を参照。
#
# 移植元との違い:
#   - 二・三・四・中・下・乙・丙・丁・地・人 の退避領域を 12 個の変数でなく
#     Hash（slots）に持ち、閉じる点（一・上・甲・天）ごとの表（CLOSERS）で吐き出す。
#   - 走査の終わりに未解決の返り点（対応する一・上・甲・天がない、レ点・竪点の
#     直後で文が終わる）が残った場合は、黙って捨てず Reorder::Error を送出する。
#
# 処理はコントロールブレーク処理に近い。
#   stock    … 現在のまとまり（1 字、または レ・竪点で連結した複数字）
#   ren/tate … 次の字を stock の先頭／末尾に連結するための保留フラグ
#   slots    … 後で読む（二・中・乙…）まとまりの退避領域
#   pending  … 順序点を見たが、レ点の連結待ちでまだ処理していないもの

module KanbunKa
module Kanbun
  module Reorder
    class Error < StandardError; end

    # 閉じる点 → その点の直後に読む退避領域の順序
    CLOSERS = {
      '一' => %w[二 三 四],
      '上' => %w[中 下],
      '甲' => %w[乙 丙 丁],
      '天' => %w[地 人]
    }.freeze

    module_function

    # units: Array<Aozora::Unit> → Array<Aozora::Unit>（読む順）
    def reorder(units)
      out = []
      slots = {}
      stock = []
      ren = tate = false
      pending = nil

      units.each do |orig|
        unit = orig
        if orig.saidoku?
          # 再読文字: 一度目の読みはその場で出力し、二度目の読みを返り点に従って並べる
          out << orig
          unit = orig.second_reading
        end

        if ren
          stock.unshift(unit)
          ren = false
        elsif tate
          stock.push(unit)
          tate = false
        else
          stock = [unit]
        end

        mark = orig.order_mark
        pending = mark if mark

        if orig.ren?
          ren = true # 「一レ」「甲レ」は順序点を pending に残したまま、次の字を連結する
        elsif orig.tate?
          tate = true
        elsif pending
          flush(pending, stock, out, slots)
          pending = nil
        else
          out.concat(stock)
        end
      end

      check_unresolved!(ren, tate, pending, slots)
      out
    end

    # 閉じる点なら stock を出力して退避分を続け、それ以外は退避領域に積む。
    def flush(mark, stock, out, slots)
      if (followers = CLOSERS[mark])
        out.concat(stock)
        followers.each { |m| out.concat(slots.delete(m) || []) }
      else
        slots[mark] = stock
      end
    end

    def check_unresolved!(ren, tate, pending, slots)
      problems = []
      problems << 'レ点の直後に字がありません' if ren
      problems << '竪点の直後に字がありません' if tate
      problems << "順序点「#{pending}」が処理されていません" if pending
      problems << "対応する閉じ点がなく、読まれなかった順序点: #{slots.keys.join}" unless slots.empty?
      raise Error, problems.join(' / ') unless problems.empty?
    end

    private_class_method :flush, :check_unresolved!
  end
end
end # module KanbunKa
