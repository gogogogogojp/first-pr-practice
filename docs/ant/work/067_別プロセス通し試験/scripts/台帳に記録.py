"""アント（実行）の工程を記録する。別プロセスで実行する。

使い方:
  python 台帳に記録.py --依頼ID 067-D --版 v1 --成果物 <成果物ファイル>      # 完了の記録
  python 台帳に記録.py --依頼ID 067-E --版 v1 --開始のみ                    # 開始だけの記録（停止の模擬）
  （--記録時刻 2026-11-24T10:00:00 を付けると、その時刻で記録する。模擬試験用）

動作:
  - 完了の記録：成果物ファイルが存在することを確かめる。
    同じ依頼ID・版の完了記録が既にあれば、再配達とみなして記録せず終了する（終了コード3）。
  - 成果物のSHA-256（内容の指紋）を記録し、次の工程が同じ内容か確かめられるようにする
  - 開始のみ：成果物は無くてよい。ハチが「開始から何分たったか」を判定するための記録
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime
from pathlib import Path

from 台帳 import REPO_ROOT, 完了記録を探す, 台帳を追記


def 解析する() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="アントの工程を台帳に記録する")
    parser.add_argument("--依頼ID", required=True)
    parser.add_argument("--版", required=True)
    parser.add_argument("--成果物", type=Path)
    parser.add_argument("--開始のみ", action="store_true")
    parser.add_argument("--記録時刻", help="模擬試験用。例: 2026-11-24T10:00:00")
    args = parser.parse_args()
    if not args.開始のみ and args.成果物 is None:
        parser.error("完了の記録には --成果物 が必要")
    return args


def 記録時刻を決める(引数: str | None) -> str:
    if 引数 is None:
        return datetime.now().isoformat(timespec="seconds")
    return datetime.fromisoformat(引数).isoformat(timespec="seconds")


def main() -> int:
    args = 解析する()
    時刻 = 記録時刻を決める(args.記録時刻)

    if args.開始のみ:
        記録 = {
            "依頼ID": args.依頼ID,
            "版": args.版,
            "工程": "アント作成",
            "状態": "開始",
            "理由": [],
            "記録時刻": 時刻,
            "記録プロセスID": os.getpid(),
        }
        台帳を追記(記録)
        print(json.dumps({"結果": "開始を記録した", "依頼ID": args.依頼ID, "版": args.版,
                          "記録時刻": 時刻, "プロセスID": os.getpid()}, ensure_ascii=False))
        return 0

    成果物 = args.成果物.resolve()
    if not 成果物.is_file():
        print(json.dumps({"結果": "エラー", "理由": f"成果物が無い: {成果物}"}, ensure_ascii=False))
        return 2

    既存 = 完了記録を探す(args.依頼ID, args.版)
    if 既存 is not None:
        print(json.dumps({"結果": "重複（再配達）のため記録しない", "依頼ID": args.依頼ID,
                          "版": args.版, "既存の成果物": 既存.get("成果物"),
                          "既存の記録時刻": 既存.get("記録時刻"), "プロセスID": os.getpid()},
                         ensure_ascii=False))
        return 3

    指紋 = hashlib.sha256(成果物.read_bytes()).hexdigest()
    記録 = {
        "依頼ID": args.依頼ID,
        "版": args.版,
        "工程": "アント作成",
        "状態": "完了",
        "成果物": 成果物.relative_to(REPO_ROOT).as_posix(),
        "成果物SHA256": 指紋,
        "理由": [],
        "記録時刻": 時刻,
        "記録プロセスID": os.getpid(),
    }
    台帳を追記(記録)
    print(json.dumps({"結果": "記録した", "依頼ID": args.依頼ID, "版": args.版,
                      "プロセスID": os.getpid(), "成果物SHA256": 指紋}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
