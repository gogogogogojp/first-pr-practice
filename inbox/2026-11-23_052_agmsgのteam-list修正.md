# 依頼052：agmsgのteam-listのパス渡し修正

## 背景

- 依頼051の報告（reports/2026-11-23_agmsgのチーム設定ファイルの所在確認.md）で、チーム設定ファイル（`teams/<チーム名>/config.json`）は3チームとも存在し、JSONとして正常と確認された。
- `team-list.sh --json --scope all` が3チームを「読めない」と判定する原因は、`scripts/team-list.sh` が Git Bash 形式のパス（`/c/Users/...`）をそのまま Windows 版 Python の `scripts/internal/team-list.py` に渡しているため。Windows 形式（`C:/Users/...`）で指定すると Python は読める。

## やること

1. `scripts/team-list.sh` を修正し、各 `config.json` のパスを `cygpath -m` で Windows 形式に変換してから Python に渡す。
2. 修正後、`team-list.sh --json --scope all` が3チーム（`handoff-test`・`ai-team`・`moko-045-test`）を含めて出力することを確認する。
3. 他の Python 補助スクリプトも同じ形式のパスを渡していないか、読み取りで確認する（見つかれば報告書に書く。修正はこの依頼の範囲内なら行ってよい）。
4. 報告書を reports/2026-11-23_agmsgのteam-list修正.md に書くこと。

## 注意

- 修正するのは agmsg のスクリプト（`~/.agents/skills/agmsg/` 配下）のみ。チーム設定ファイル（`config.json`・`roster.jsonl`）の作り直しは不要で、触らないこと。
- テスト用チーム `moko-045-test` の削除はしないこと（削除は要承認のため、モコが別途判断する）。
- `agmsgd` の警告（`ops.sh` の追記）は、この依頼では修正しないこと（残すか記録を更新するかは別途決める）。
- PCがインターネット未接続で処理できなかった場合は失敗扱いにせず、接続が戻ったらそのまま進める。
- 報告書は必ず書くこと（ボード更新のもとになる）。
