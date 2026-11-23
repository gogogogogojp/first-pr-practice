"""オウル（検収）の工程。別プロセスで実行する。

使い方:
  python 検収.py --依頼ID 063-C --版 v2

動作:
  - 台帳から、同じ依頼ID・版の「アント作成・完了」の記録を読む（前の工程の出力を受け取る）
  - 成果物ファイルの指紋（SHA-256）が、アントの記録と一致するか確かめる
  - 機械的な形式チェック（依頼ID・版・行頭の「※架空データ」・アフィリエイト表記・URL/価格の混入）
  - 結果（OK / NG）と理由を台帳に追記する

注意: 本文の品質は見ない。形式チェックのみ。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

from 台帳 import REPO_ROOT, 台帳を読む, 台帳を追記


def 解析する() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="オウルの検収を行い台帳に記録する")
    parser.add_argument("--依頼ID", required=True)
    parser.add_argument("--版", required=True)
    return parser.parse_args()


def 形式を検査する(本文: str, 依頼ID: str, 版: str) -> list[str]:
    理由 = []
    if not re.search(rf"依頼ID:\s*{re.escape(依頼ID)}\b", 本文):
        理由.append(f"依頼ID {依頼ID} が本文に無い")
    if not re.search(rf"版:\s*{re.escape(版)}\b", 本文):
        理由.append(f"版 {版} が本文に無い")
    if not re.search(r"(?m)^※架空データ", 本文):
        理由.append("「※架空データ」の注記が行頭に無い")
    if "アフィリエイト表記" not in 本文:
        理由.append("アフィリエイト表記の欄が無い")
    if re.search(r"https?://", 本文):
        理由.append("URLが混入している")
    if re.search(r"[¥￥]|\d[\d,]*\s*円", 本文):
        理由.append("価格（円・¥）が混入している")
    return 理由


def main() -> int:
    args = 解析する()
    記録一覧 = 台帳を読む()

    アント記録 = [
        r for r in 記録一覧
        if r.get("依頼ID") == args.依頼ID and r.get("版") == args.版 and r.get("工程") == "アント作成"
    ]
    if not アント記録:
        理由 = [f"アントの記録が台帳に無い（依頼ID {args.依頼ID}・版 {args.版}）"]
        判定 = "NG"
        対象 = None
        指紋一致 = None
    else:
        直近 = アント記録[-1]
        対象 = REPO_ROOT / 直近["成果物"]
        if not 対象.is_file():
            理由 = [f"成果物が見つからない: {直近['成果物']}"]
            判定 = "NG"
            指紋一致 = None
        else:
            実体 = 対象.read_bytes()
            指紋一致 = hashlib.sha256(実体).hexdigest() == 直近["成果物SHA256"]
            理由 = []
            if not 指紋一致:
                理由.append("成果物の内容がアントの記録と一致しない（受け渡し中に変わった可能性）")
            理由 += 形式を検査する(実体.decode("utf-8"), args.依頼ID, args.版)
            判定 = "OK" if not 理由 else "NG"

    記録 = {
        "依頼ID": args.依頼ID,
        "版": args.版,
        "工程": "オウル検収",
        "状態": 判定,
        "成果物": 対象.relative_to(REPO_ROOT).as_posix() if 対象 else None,
        "理由": 理由,
        "記録時刻": datetime.now().isoformat(timespec="seconds"),
        "記録プロセスID": os.getpid(),
    }
    台帳を追記(記録)
    print(json.dumps({"判定": 判定, "依頼ID": args.依頼ID, "版": args.版,
                      "指紋一致": 指紋一致, "理由": 理由, "プロセスID": os.getpid()},
                     ensure_ascii=False, indent=2))
    return 0 if 判定 == "OK" else 1


if __name__ == "__main__":
    sys.exit(main())
