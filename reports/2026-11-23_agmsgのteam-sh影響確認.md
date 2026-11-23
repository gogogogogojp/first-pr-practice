# 依頼056：team.sh 等への影響確認 報告

- 処理日：2026-11-23
- 依頼：`inbox/2026-11-23_056_team-sh等への影響確認.md`
- 使ったモデル：Claude Haiku 5.5（claude-haiku-5-5）
- 作業範囲：依頼ファイルの指定どおり、agmsg のスクリプト（`~/.agents/skills/agmsg/` 配下）は**読み取りと読み取り系コマンドの実行のみ**。書き込みは行っていません。このリポジトリ内も変更していません（報告書と依頼の結果欄のみ追記）。

## 結論

- **team.sh・remote.sh・doctor.sh・team-list.sh はすべて正常に動きました。**
- 052 と同種の「Windows パスを Python に渡す」問題は、**見つかりませんでした**。
- チーム設定ファイル（`config.json`・`roster.jsonl`）は、確認の前後で **MD5 が一致**し、変更ありません。
- `ops.sh` の追記は、**残す**ことを推奨します（理由は下の「ops.sh の判断」）。

## 確認した機能と結果

| 機能 | 実行したコマンド | 結果 |
|---|---|---|
| team.sh（ai-team） | `team.sh ai-team`・`--json` | 終了コード 0、2メンバーを表示 |
| team.sh（handoff-test） | `team.sh handoff-test` | 終了コード 0、5メンバーを表示 |
| team.sh（moko-045-test） | `team.sh moko-045-test` | 終了コード 0、2メンバーを表示 |
| team.sh（存在しないチーム） | `team.sh no-such-team-056` | 「Team not found」、終了コード 1（想定どおり） |
| team-list.sh | `--json --scope all` | 終了コード 0、3チーム（ai-team・handoff-test・moko-045-test） |
| remote.sh（status） | `remote.sh status` | 終了コード 0、「No teams are connected.」 |
| doctor.sh（読み取り専用） | `doctor.sh --team moko-045-test` | 終了コード 1、警告2件（下の「見つかった問題」） |
| session-start.sh | コード読みのみ（実行せず） | `remote.sh status` を呼ぶだけで、パス処理なし。問題なし |

- 実行しなかったもの：`team.sh --delete`・`--purge-messages`・`--force`（削除系、要承認）、`doctor.sh --fix`（修復系）、`remote.sh connect`など接続系。

## Windows パス渡しの確認（読み取り）

- Python に**ファイルパスを渡している箇所**を全件確認しました。
  - `team-list.sh`：052 で修正済み。
  - `remote.sh` 104行目：渡しているのはチーム名の文字列。パスではない。問題なし。
  - `remote.sh` 584行目：標準入力経由。問題なし。
  - `remote.sh` 3056行目：チーム名を引数で渡すだけ。問題なし。
  - `drivers/types/antigravity/*.py`：このPCでは使っていない種類。範囲外として未確認。
- Node.js に渡すパス（`jsonl-sync.mjs` 等）：このPCの保存方式（sqlite）では通らない経路のため、実行は未確認。コード上は問題の兆候なし。
- team.sh は Python を使わないため、052 と同じ問題は起きません。

## ops.sh の判断（変更はしていません）

- 対象：`scripts/drivers/terminals/orca/ops.sh`（2026-11-20 に8行を追記）。
- 確認した事実：
  - 追記前のバックアップ（`ops.sh.bak-2026-11-20`）との差分は、追記部分だけ。
  - 追記内容は「`orca` コマンドが PATH に無い時だけ、Orca の bin フォルダを足す」処理。既存の処理は変わりません。
  - 警告は「導入記録のハッシュと合わない」というだけで、動作の停止は起きていません。
- **推奨：追記は残す。** 理由は次の3つです。
  1. 既存の動作を変えず、`orca` が無い時だけ働く。
  2. 元に戻すと、Codex 起動時に `orca` が見つからない問題が再発しうる。
  3. 記録の更新（`install.sh --update`）は、下の「見つかった問題」が直るまで失敗しやすい。
- 次の作業：`install.sh --update` で導入記録を更新するのは、シンボリックリンクの問題を先に直してから、別の依頼で行う。

## 見つかった問題（この依頼では修正していません）

1. **doctor の警告（シンボリックリンク作成不可）**
   - 内容：`state of 'agmsg' stays in .../agmsg` と `state is degraded since 2026-11-12`。
   - 原因（doctor の表示より）：Windows で `/c/Users/Admin/.agmsg/agmsg` へのシンボリックリンクが作れない。
   - 影響：agmsg の動作は続いている（`agmsgd` は ready）。ただし doctor は毎回警告を出す。
   - 対応案：Windows の開発者モード（シンボリックリンク許可）を有効にしてから `install.sh --update --cmd agmsg` を実行する。**PC設定の変更と再インストールを伴うため、次の依頼で要承認**。
2. **handoff-test の `messaging_socket_missing`**（前回 2026-11-23 の所在確認報告で既出）。今回は未調査。ops.sh とは別問題。

## 残るリスク・未確認

- 未確認：`team.sh` の削除系（`--delete` 等）。依頼の注意どおり、実行していません。
- 未確認：macOS・Linux での動作（このPCは Windows のみ）。
- 未確認：`drivers/types/antigravity` の Python 処理（このPCでは未使用）。
- テスト用チーム `moko-045-test` は削除していません（削除は要承認）。

## 次にやること

1. 残すかどうかの最終確認（推奨は「残す」）。
2. シンボリックリンク問題の対応（PC設定変更を伴うため、要承認）。
3. `handoff-test` の `messaging_socket_missing` の調査（別依頼）。
