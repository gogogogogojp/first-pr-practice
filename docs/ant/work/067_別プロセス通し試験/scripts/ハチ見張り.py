"""ハチ（見張り）の工程。別プロセスで実行する。自動修理はしない（検知と報告まで）。

使い方:
  python 見張り.py --依頼ID 063-C --版 v2

動作:
  - 台帳から同じ依頼ID・版の記録を読み、工程の状態を判定する
    - アント記録が無い → 「未到達（アント）」
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


def 解析する() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ハチの見張りを行い台帳に記録する")
    parser.add_argument("--依頼ID", required=True)
    parser.add_argument("--版", required=True)
    return parser.parse_args()


def main() -> int:
    args = 解析する()
    対象 = [r for r in 台帳を読む() if r.get("依頼ID") == args.依頼ID and r.get("版") == args.版]
    アント = [r for r in 対象 if r.get("工程") == "アント作成"]
    オウル = [r for r in 対象 if r.get("工程") == "オウル検収"]

    if not アント:
        状態 = "未到達（アント）"
    elif not オウル:
        状態 = "未到達（オウル）"
    elif オウル[-1]["状態"] == "NG":
        状態 = "工程停止（NG）"
    else:
        状態 = "モコ承認待ち"

    記録 = {
        "依頼ID": args.依頼ID,
        "版": args.版,
        "工程": "ハチ見張り",
        "状態": 状態,
        "理由": [],
        "記録時刻": datetime.now().isoformat(timespec="seconds"),
        "記録プロセスID": os.getpid(),
    }
    台帳を追記(記録)
    print(json.dumps({"依頼ID": args.依頼ID, "版": args.版, "状態": 状態,
                      "プロセスID": os.getpid()}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
