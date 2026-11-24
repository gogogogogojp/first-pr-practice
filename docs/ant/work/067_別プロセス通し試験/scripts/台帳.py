"""台帳（JSON）の読み書きを共通化する。各工程のスクリプトから読み込まれる。

台帳の場所: docs/ant/work/067_別プロセス通し試験/台帳_067.json
形式: JSON配列。1件 = 1工程の記録（依頼ID・版・工程・状態・理由・時刻・プロセスID）。
書き込みは一時ファイルに書いてから置き換える（途中で壊れないため）。
"""

from __future__ import annotations

import json
import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[5]
台帳パス = Path(__file__).resolve().parents[1] / "台帳_067.json"


def 台帳を読む() -> list[dict]:
    if not 台帳パス.exists():
        return []
    with 台帳パス.open("r", encoding="utf-8") as f:
        データ = json.load(f)
    if not isinstance(データ, list):
        raise ValueError("台帳はJSON配列である必要がある")
    return データ


def 完了記録を探す(依頼ID: str, 版: str) -> dict | None:
    """同じ依頼ID・版の「アント作成・完了」の記録を返す。無ければ None。（再配達の重複判定に使う）"""
    for r in 台帳を読む():
        if r.get("依頼ID") == 依頼ID and r.get("版") == 版 and r.get("工程") == "アント作成" and r.get("状態") == "完了":
            return r
    return None


def 台帳を追記(記録: dict) -> None:
    データ = 台帳を読む()
    データ.append(記録)
    一時 = 台帳パス.with_suffix(".json.tmp")
    with 一時.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(データ, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(一時, 台帳パス)
