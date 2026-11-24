"""ハチ（見張り）の工程。別プロセスで実行する。自動修理はしない（検知と報告まで）。

使い方:
  python ハチ見張り.py --依頼ID 063-C --版 v2
  python ハチ見張り.py --依頼ID 067-E --版 v1 --現在時刻 2026-11-24T10:40:00  # 模擬試験用

動作:
  - 台帳から同じ依頼ID・版の記録を読み、工程の状態を判定する
    - アント記録が無い → 「未到達（アント）」
    - アントが「開始」だけで完了が無い
        - 開始から閾値（既定30分）を超えた → 「アント停止（通知）」（同じ依頼IDで通知を記録）
        - 閾値内 → 「アント作業中」
    - オウルの記録が無い → 「未到達（オウル）」
    - オウルNG → 「工程停止（NG）」（モコへは進めない）
    - オウルOK → 「モコ承認待ち」（実投稿はしない）
  - 判定を台帳に「ハチ見張り」として追記する
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime

from 台帳 import 台帳を読む, 台帳を追記

停止の閾値分 = 30


def 解析する() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ハチの見張りを行い台帳に記録する")
    parser.add_argument("--依頼ID", required=True)
    parser.add_argument("--版", required=True)
    parser.add_argument("--現在時刻", help="模擬試験用。例: 2026-11-24T10:40:00。省略時は今")
    return parser.parse_args()


def 状態を判定する(対象: list[dict], 現在: datetime) -> str:
    アント完了 = [r for r in 対象 if r.get("工程") == "アント作成" and r.get("状態") == "完了"]
    アント開始 = [r for r in 対象 if r.get("工程") == "アント作成" and r.get("状態") == "開始"]
    オウル = [r for r in 対象 if r.get("工程") == "オウル検収"]

    if not アント完了:
        if not アント開始:
            return "未到達（アント）"
        経過分 = (現在 - datetime.fromisoformat(アント開始[-1]["記録時刻"])).total_seconds() / 60
        return "アント停止（通知）" if 経過分 > 停止の閾値分 else "アント作業中"
    if not オウル:
        return "未到達（オウル）"
    if オウル[-1]["状態"] == "NG":
        return "工程停止（NG）"
    return "モコ承認待ち"


def main() -> int:
    args = 解析する()
    現在 = datetime.fromisoformat(args.現在時刻) if args.現在時刻 else datetime.now()
    対象 = [r for r in 台帳を読む() if r.get("依頼ID") == args.依頼ID and r.get("版") == args.版]
    状態 = 状態を判定する(対象, 現在)

    記録 = {
        "依頼ID": args.依頼ID,
        "版": args.版,
        "工程": "ハチ見張り",
        "状態": 状態,
        "理由": [],
        "記録時刻": 現在.isoformat(timespec="seconds"),
        "記録プロセスID": os.getpid(),
    }
    台帳を追記(記録)
    print(json.dumps({"依頼ID": args.依頼ID, "版": args.版, "状態": 状態,
                      "プロセスID": os.getpid()}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
