# lib/kanbun_ka（kanbun-ka から複製したコード）

- 複製元: https://github.com/toghisumasu/kanbun-ka
- 複製したコミット: `65bb176`（Merge phase-4v-repl）
- 複製日: 2026-11-07
- 複製したもの: `lib/kanbun/` の一式（`aozora.rb`・`kakikudashi.rb`・`kunten.rb`・`lexicon.rb`・`reorder.rb`・`tree.rb`・`kanbun_parser.y`・`kanbun_parser.tab.rb`）、
  `ACKNOWLEDGMENTS.md`、`LICENSES/kanbun-javascript-MIT.txt`（MIT の条件のため一緒に置く）。
  サービス側（`app/services/kanbun_ka/`）は、`app/services/kanbun_ka/README.md` を見ること。
- 変えた箇所: 各ファイルを `module KanbunKa ... end` で包んだ（定数は `KanbunKa::Kanbun::Lexicon`、`KanbunKa::KanbunParser` のようになる）。
  それ以外は同じ。`kanbun_parser.tab.rb` は Racc の生成ファイルで、`module KanbunKa` の包みだけを手で足した
  （文法 `kanbun_parser.y` から作り直すときは、同じ包みを足す。複製元の `.y` は変えていない）。
- Zeitwerk の対象外（`config/application.rb` の `autoload_lib` の `ignore` に `kanbun_ka` を足した）。サービス側から `require` で読む。
- Rubocop の対象外（`.rubocop.yml`。複製元との差分を小さく保つため）。
- 複製元の `ACKNOWLEDGMENTS.md` の中のパス（`lib/kanbun/...`）は、複製元のまま。ここでは `lib/kanbun_ka/...` に当たる。
- 複製元に更新があっても自動では追従しない。取り込み直すときは、このファイルのコミット番号を更新する。
