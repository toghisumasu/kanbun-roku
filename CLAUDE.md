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

## 会話の区切り（segments）
区切りは原本からの派生情報。`messages` には書かず、いつでも原本から作り直せる。
（マイグレーション `20261030100000_create_segments.rb` は作成済みで、確認待ち。未実行。）
- 2026-10-30（JST）より前: 隣り合う発言（role問わず）の間隔が6時間以上空いた所で区切る。
- 2026-10-30（JST）以降: role=user の発言が次のどれかと全体一致したら終了の合図。
  こちらからは以上です / 中断します / おやすみなさい / さようなら / いってきます
  （`ConversationSegmenter::END_PHRASES` の定数。足すときはここと CLAUDE.md を直す）
- 2026-10-30（JST）以降: role=user の発言が「再開します」と全体一致したら、その発言を新しい区切りの
  最初の発言にする（reason: resume_phrase）。直前の区切りに終了の合図がなければ、暗黙に閉じる（reason: implicit）。
- 全体一致は、前後の空白・句点・感嘆符（。.！!）の差を無視して判定する。部分一致にしない。
- 終了の合図は、人間の発言が40文字以下（前後の空白を除く）のときだけ判定する。
  長い発言に合図の語が混ざっていても終了にしない。「再開します」も同じ全体一致で、部分一致にしない。
- 終了の合図の直後の assistant の返答は、閉じる側の区切りに含める。
  - 末尾が終了の合図の user 発言で終わる区切りは、返答がまだ入っていないので open として扱う。
    続き（assistant の返答など）が入ったら計算し直す。
  - ただし、最後の発言から6時間以上たっていれば、返答がなくても end_reason = end_phrase で閉じる。
    この6時間は、取り込み時刻（現在時刻）との比較で行う（`ConversationSegmenter.call` の `now:`）。
- 規則の切り替え（2026-10-30 JST の前後）は、発言ごとの時刻で行う。境界をまたぐ区切りは分けない。
- 区切りの更新:
  - 閉じた区切り（end_reason が open 以外）は更新しない。
  - open の区切りは、次の取り込みで同じ会話に新しい発言が入ったとき、その区切りだけを
    先頭の発言から計算し直して伸ばす（または閉じる）。
  - 合図のない末尾の区切りも、最後の発言から6時間以上たっていれば（取り込み時刻 now との比較）
    end_reason = gap で閉じる。
  - 日記は open の区切りには生成しない。
  - 再計算は `SegmentRebuilder.rebuild!`（`bin/rails segments:rebuild`。既定は dry-run、実書き込みは `APPLY=1`。
    書き込みは1つのトランザクション）。取り込みタスクは `APPLY=1` のとき最後に呼ぶ。
    最後の閉じた区切りより後の発言をまとめて区切り直し、その最初の start_reason は
    前の区切りの end_reason（gap→gap / end_phrase→after_end / implicit→resume_phrase）で決める。
- segments は `resumed`（boolean）と `continued_from_id`（同じ会話の直前の区切り。なければ NULL）を持つ。
- 区切りの日付は、開始時刻の日本時間の暦日。
  25時制の表示は表示側で計算する（区切りの日付より後の暦日になった分を、24時・25時と出す）。DBには持たない。

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

## バックアップと復元
`bin/backup-db` が `kanbun_roku_development`（primary のみ。queue は再作成できるので対象外）を
`pg_dump` → gzip し、`kanbun_roku_development-YYYYMMDD.sql.gz` として次の保存先のうち使えるものすべてに置く。
同じ日に再実行すると、その日のファイルを置き換える。保存先ごとに7世代を残し、古いものを消す。
- `/Volumes/externalHDD/backups/kanbun-roku/`（必須。マウントされていない、または書けなければ ERROR）
- `/Volumes/externalSDD/backups/kanbun-roku/`（ボリュームがマウントされているときだけ）

未マウントのボリューム配下は `mkdir -p` もしない。1つでも失敗すると終了コードは 1。
結果は `log/backup.log`（失敗は `ERROR`）。バックアップファイルはリポジトリの外に置き、`*.sql.gz` は Git 管理外。
定期実行は launchd（`config/launchd/com.kanbun-roku.backup.plist`、毎日 03:00）。
launchd から外付けディスク上のスクリプトは実行できない（`Operation not permitted`）ので、
スクリプトは内蔵ディスクにコピーして動かす。リポジトリ側の `bin/backup-db` が原本で、直したらコピーし直す。
外付けへの書き込み（バックアップ先と `log/backup.log`）には、`/bin/bash` へのフルディスクアクセスの許可が要る
（システム設定 → プライバシーとセキュリティ。権限の変更は手作業で行う）。
plist の `ProgramArguments` は、スクリプトを直接呼ばず `["/bin/bash", "<スクリプトのパス>"]` の形にする。
スクリプトを直接起動（シバンの `/usr/bin/env bash` 経由）にしたときは、上の許可を付けても
外付けへの `cp` が `Operation not permitted` になった。`/bin/bash` を直接起動すると書けた
（理由は未調査。許可の対象が `/bin/bash` として扱われる形で起動する必要がある、とみている）。
この形を崩したら、登録して `kickstart` し、`log/backup.log` に「終了: 成功」が出ることを確かめる。
```sh
# 登録（__HOME__ はホームのパスに置き換える）
mkdir -p ~/Library/Logs/kanbun-roku "$HOME/Library/Application Support/kanbun-roku"
install -m 755 bin/backup-db "$HOME/Library/Application Support/kanbun-roku/backup-db"
sed "s#__HOME__#$HOME#g" config/launchd/com.kanbun-roku.backup.plist > ~/Library/LaunchAgents/com.kanbun-roku.backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kanbun-roku.backup.plist
launchctl kickstart -k gui/$(id -u)/com.kanbun-roku.backup   # 試しに今すぐ実行
launchctl print gui/$(id -u)/com.kanbun-roku.backup | grep "last exit code"
# 解除
launchctl bootout gui/$(id -u)/com.kanbun-roku.backup
# bin/backup-db や plist を直したとき: 上の install / sed をやり直し、bootout → bootstrap
```
launchd 自体のエラーは `~/Library/Logs/kanbun-roku/backup.launchd.log` に出る。
`log/backup.log` に書けないときも、ここに出る。

### 復元の確認（別名DBで。本物のDBには触れない）
バックアップが使えるかは、別名のDBに戻して確かめる。
```sh
F=/Volumes/externalHDD/backups/kanbun-roku/kanbun_roku_development-YYYYMMDD.sql.gz
createdb kanbun_roku_restore_check
gunzip -c "$F" | psql -q -v ON_ERROR_STOP=1 -d kanbun_roku_restore_check
psql kanbun_roku_restore_check -c "select count(*) from messages"   # 件数が本物のDBと合うか
psql kanbun_roku_restore_check -c "select tgname from pg_trigger where tgrelid = 'messages'::regclass and not tgisinternal"
                                                                     # messages_no_update_delete / messages_no_truncate があるか
dropdb kanbun_roku_restore_check
```

### 本物のDBへの復元
本物のDBを置き換える作業なので、サーバーと `bin/jobs` を止めてから行う。
1. 今のDBを `pg_dump kanbun_roku_development > data/backup-YYYYMMDD.sql` で退避する。
2. `dropdb kanbun_roku_development && createdb kanbun_roku_development`
   （`bin/rails db:drop` は保護環境のため止まる。ここでは意図して直接 `dropdb` を使う）。
3. `gunzip -c "$F" | psql -q -v ON_ERROR_STOP=1 -d kanbun_roku_development`
4. queue DB は `bin/rails db:prepare` で作り直す。

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
