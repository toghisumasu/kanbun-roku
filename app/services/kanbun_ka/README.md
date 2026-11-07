# app/services/kanbun_ka（kanbun-ka から複製したコード）

- 複製元: https://github.com/toghisumasu/kanbun-ka、コミット `65bb176`（Merge phase-4v-repl）、複製日 2026-11-07。
- 複製したもの: `kanbun_translator_service.rb`・`kanbun_parser_service.rb`・`kanbun_bnf_parser.rb`・`mecab_adapter.rb`・`skeleton_builder.rb`。
  複製しなかったもの: `kanbun_translator_service_jp.rb`（同じ定数 `KanbunTranslatorService` を定義する旧版で、衝突するため）。
- 変えた箇所: 各ファイルを `module KanbunKa ... end` で包んだ（`KanbunKa::KanbunTranslatorService` などになる）。
  `kanbun_parser_service.rb` と `kanbun_translator_service.rb` の `require` のパスを、`lib/kanbun_ka/` を指すように直した。それ以外は同じ。
- ファイル名と定数名を合わせるため、`config/initializers/inflections.rb` に acronym `BNF` と `MeCab` を足した。
- 変換の流れ: MeCab → BNF パーサー（骨格）→ LLM（Ollama の `qwen3:8b`、白文）→ Racc パーサー（訓点・書き下し）。
  入口は `KanbunKa::KanbunTranslatorService.call(日本語の一文)`。書き下しは Racc パーサーの出力だけを使い、LLM には書かせない。
- 依存: コマンド `mecab`（IPA 辞書）と、`localhost:11434` の Ollama（モデル `qwen3:8b`）。gem は `racc`（nokogiri 経由で入っている）。
- 試作の使い方は `rendering_trial:run` / `rendering_trial:report`（`lib/tasks/rendering_trial.rake`）。
- ライセンスと謝辞: `lib/kanbun_ka/ACKNOWLEDGMENTS.md` と `lib/kanbun_ka/LICENSES/`。
