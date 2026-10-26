# kanbun-roku（渡世日月漢文録）

Claudeとの会話ログをDBに原本保存し、そこへリンクした漢文調ダイアリーを生成するRailsアプリ。

## 原則（厳守）
- 原本（messages）は追記のみ。更新・削除しない。
  - モデル側で `readonly?` を永続化済みレコードで true にし、`before_destroy` で例外を出す。
  - DB側でも UPDATE/DELETE/TRUNCATE を拒否するトリガーを置く（アプリのバグから原本を守るため）。
  - 例外的に消す場合は「原本の例外削除手順」に従う。
- ダイアリーは原本からの派生物。いつでも原本から再生成できる。
  - 本文と diary_links はいつ作り直してもよい。生成に必要な情報を原本以外に持たせない。
- ダイアリーの各記述は、根拠となる原本の発言にリンクする（diary_links）。
  - 今は日単位のリンク。曽良モードの出力形式を決める段階で、diary_links に文の位置の列を足す。
- 注釈（annotations）は後日の考察を足す層。原本には触れない。

## テーブル
- messages: session_id, external_id, role, body, occurred_at, source
  - (source, external_id) に一意制約（再取り込みで重複させない）
- diary_entries: entry_date, body_kanbun, body_kundoku
- diary_links: diary_entry_id, message_id
- annotations: annotatable（polymorphic: Message / DiaryEntry）, body

## 生成（2段構成）
1. 曽良モード: 1日分のログから事実だけを簡潔な漢文調で記録（リンク付き）
2. 芭蕉モード: 1を材料に紀行文として文章化（後回し）
- 生成は Solid Queue のジョブで実行。日付指定で再生成できること。
- LLM はローカルの Ollama（`qwen3:14b` 想定, http://localhost:11434）。

## 環境
- Ruby 3.3.13（`.ruby-version` で固定）/ Rails 8.1系 / PostgreSQL
- gem は vendor/bundle（`bundle config set --local path vendor/bundle`）
- Mac mini のローカル専用。デプロイは当面しない。
- Kamal、Thruster、Solid Cable は使わない。

## 注意
- 会話ログは機微な個人情報。外部送信しない。
  - LLM 呼び出しはローカルの Ollama のみ。外部 API・外部サービスへ送らない。
  - 会話ログの実データ・DBダンプはリポジトリにコミットしない。

## 実装上の決まり
- メインDBのスキーマは `db/structure.sql`（原本保護のトリガーを保存するため。`schema.rb` には書き出されない）。
- DiaryEntry は entry_date で一意。作り直すときは同じ行の本文を書き換え、diary_links を入れ替える。
  行を消して作り直すと、その日のダイアリーに付けた注釈が失われるため。
- 注釈が付いた DiaryEntry は削除できない（restrict）。
- テストで messages の fixture は使わない（fixture の読み込みが DELETE を発行し、トリガーで拒否されるため）。
- 取り込み対象は当面 claude.ai のエクスポート（conversations.json）のみ。source は `claude_ai`。
  - エクスポートは `data/` に置く（.gitignore 済み）。
  - パーサーは実物のサンプルでスキーマを確認してから書く。external_id に何を使うかもその時に決める。

## コマンド
- `bin/rails server` / `bin/jobs`（Solid Queue のワーカー。development でも Solid Queue を使う）
- `bin/rails test` / `bin/rubocop`
- DB: development は primary（kanbun_roku_development）と queue（kanbun_roku_development_queue）の2つ。

## 開発用DBコマンドの注意
- development のDBに本物の原本が入る。そのため development も保護環境にしてある
  （`config.active_record.protected_environments`）。
  `db:drop` / `db:reset` / `db:schema:load` / `db:truncate_all` / `db:seed:replant` は止まる。
- Rails は truncate や fixture の読み込みのときに `DISABLE TRIGGER ALL` を実行する。
  このとき原本保護のトリガーも止まるので、上の保護を外さないこと。
- どうしても作り直すときは、まず `pg_dump kanbun_roku_development` でバックアップを取る
  （出力は `data/` に置く）。そのうえで `DISABLE_DATABASE_ENVIRONMENT_CHECK=1` を付けて実行する。
- test 環境は保護しない（`bin/rails test` は普通に動く）。

## 原本の例外削除手順
誤って取り込んだ会話や、消したい機微な発言を消すときだけ使う。アプリからは消せない。
1. `pg_dump kanbun_roku_development > data/backup-YYYYMMDD.sql` でバックアップを取る。
2. 対象を (source, external_id) で特定し、1つのトランザクションで次を実行する
   （`DISABLE TRIGGER` もトランザクション内なら、失敗時に巻き戻る）。
   ```sql
   BEGIN;
   ALTER TABLE messages DISABLE TRIGGER messages_no_update_delete;
   DELETE FROM annotations WHERE annotatable_type = 'Message'
     AND annotatable_id IN (SELECT id FROM messages WHERE source = '...' AND external_id = '...');
   DELETE FROM diary_links
     WHERE message_id IN (SELECT id FROM messages WHERE source = '...' AND external_id = '...');
   DELETE FROM messages WHERE source = '...' AND external_id = '...';
   ALTER TABLE messages ENABLE TRIGGER messages_no_update_delete;
   COMMIT;
   ```
3. 消した発言の日付のダイアリーを再生成する。本文に、消した発言の内容が残っているため。
4. 機微情報を消すのが目的なら、手順1のバックアップも消す。
