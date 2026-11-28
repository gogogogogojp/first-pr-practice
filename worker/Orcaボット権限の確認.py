"""Orcaのボットの権限（Permissions）を、読み取り専用で確認する（依頼129）。

使い方: python -I worker/Orcaボット権限の確認.py [ボット名]   （既定: codex2）

- Orcaの保存データ（profile-state.db）を読み取り専用で開く。書き込みはしない。
- ワーカーは画面の無い場所（Session 0）で動き、orca CLIがOrcaにつながらないため、
  ファイルから直接確かめる。
- 終了コード: 0=承認モード(ask) / 1=ボット無し / 2=承認モード以外 / 3=読めない
"""
from __future__ import annotations

import json
import os
import pathlib
import sqlite3
import sys

ASK = "ask"


def db_path() -> pathlib.Path:
    return (pathlib.Path(os.environ["APPDATA"]) / "orca" / "profiles"
            / "local-default" / "profile-state.db")


def load_domain(con: sqlite3.Connection, domain: str):
    row = con.execute(
        "select payload from profile_state_documents where domain=?", (domain,)
    ).fetchone()
    return json.loads(row[0]) if row else None


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # ログ（UTF-8）で文字化けさせない
    name = sys.argv[1] if len(sys.argv) > 1 else "codex2"
    path = db_path()
    if not path.exists():
        print(f"未確認: Orcaの保存データが見つかりません（{path}）")
        return 3
    try:
        con = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
        bots = load_domain(con, "bots") or []
        settings = load_domain(con, "settings") or {}
    except (sqlite3.Error, json.JSONDecodeError) as e:
        print(f"未確認: 保存データを読めませんでした（{type(e).__name__}）")
        return 3

    folder = pathlib.Path.home() / ".orca" / "bots" / name
    bot = next((b for b in bots if isinstance(b, dict) and b.get("name") == name), None)
    if bot is None:
        print(f"ボット「{name}」はまだありません（フォルダ: {'あり' if folder.exists() else 'なし'}）")
        return 1

    mode = bot.get("permissionMode")
    agent = bot.get("agent", "不明")
    if mode is None:
        # 「Same as chats」= チャットの設定を引き継ぐ。Codexは個別設定(own)が優先される。
        override = (settings.get("agentPermissionOverrides") or {}).get(agent)
        inherited = override or settings.get("agentPermissionDefault")
        print(f"ボット「{name}」（中身: {agent}）: Same as chats（引き継ぎ先: {inherited}）→ 承認モードではない扱い")
        return 2
    print(f"ボット「{name}」（中身: {agent}）: 権限 = {mode}")
    return 0 if mode == ASK else 2


if __name__ == "__main__":
    sys.exit(main())
