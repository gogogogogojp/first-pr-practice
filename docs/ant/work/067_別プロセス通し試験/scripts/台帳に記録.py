"""アント（実行）の工程を記録する。別プロセスで実行する。

使い方:
  python -I 台帳に記録.py --依頼ID 067-D --版 v1 --成果物 <成果物ファイル>

動作:
  - 成果物ファイルが存在することを確かめる
  - 台帳（台帳_067.json）に「アント作成・完了」を1件追記する
  - 成果物のSHA-256（内容の指紋）を記録し、次の工程が同じ内容か確かめられるようにする
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime
from pathlib import Path

from 台帳 import REPO_ROOT, 台帳を追記


def 解析する() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="アントの工程を台帳に記録する")
    parser.add_argument("--依頼ID", required=True)
    parser.add_argument("--版", required=True)
    parser.add_argument("--成果物", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = 解析する()
    成果物 = args.成果物.resolve()
    if not 成果物.is_file():
        print(json.dumps({"結果": "エラー", "理由": f"成果物が無い: {成果物}"}, ensure_ascii=False))
        return 2

    指紋 = hashlib.sha256(成果物.read_bytes()).hexdigest()
    記録 = {
        "依頼ID": args.依頼ID,
        "版": args.版,
        "工程": "アント作成",
        "状態": "完了",
        "成果物": 成果物.relative_to(REPO_ROOT).as_posix(),
        "成果物SHA256": 指紋,
        "理由": [],
        "記録時刻": datetime.now().isoformat(timespec="seconds"),
        "記録プロセスID": os.getpid(),
    }
    台帳を追記(記録)
    print(json.dumps({"結果": "記録した", "依頼ID": args.依頼ID, "版": args.版,
                      "プロセスID": os.getpid(), "成果物SHA256": 指紋}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
