# 謝辞

kanbun-ka の訓点処理（`lib/kanbun/aozora.rb`・`lib/kanbun/reorder.rb`・`lib/kanbun/kakikudashi.rb`）は、
次のオープンソースプロジェクトの記法とアルゴリズムに学んでいます。

## 漢文訓読 JavaScript（kanbun-javascript）

- リポジトリ: https://github.com/kawabata/kanbun-javascript
- 作者: Teruyuki Kobayashi（小林照幸）氏、KAWABATA, Taichi 氏
- ライセンス: MIT License（全文は `LICENSES/kanbun-javascript-MIT.txt`）

学んだ点:

- 青空文庫の注記記法を拡張した「漢文注記記法」（送り仮名・返り点・再読文字・置き字・竪点）
  を正本とし、原文・訓点・書き下し文をそこから導くという設計
- 返り点（レ・一二三四・上中下・甲乙丙丁・天地人、および一レ・甲レ）を一回の走査で
  書き下し順に並べ替える方法（`kanbun_reorder`）

`kanbun.js` の `kanbun_reorder` の処理手順を Ruby に移植・再構成したものが `Kanbun::Reorder` です。
移植元と異なる点（未解決の返り点を例外とする、順序点の退避領域を表で持つ、など）は
`lib/kanbun/reorder.rb` の冒頭コメントに記しています。

## 表記上の注意

MIT License の条件に従い、移植元の著作権表示とライセンス文を
`LICENSES/kanbun-javascript-MIT.txt` に、そのまま保存しています。
