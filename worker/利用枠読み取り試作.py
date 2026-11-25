"""
Claude Code と Codex の利用枠を、PC内のセッションログから読む試作スクリプト。

- 読むもの: 使用量の数字（トークン数・利用率・リセット時刻）だけ。
- 読まないもの: 認証ファイル（.credentials.json / auth.json）。
- 外部送信はしない。書き込みもしない（標準出力に表示するだけ）。

使い方（PowerShell）:
  python -I "C:\\Users\\Admin\\repos\\first-pr-practice\\worker\\利用枠読み取り試作.py"
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9))
HOME = Path.home()
CODEX_SESSIONS = HOME / ".codex" / "sessions"
CLAUDE_PROJECTS = HOME / ".claude" / "projects"


def parse_ts(value: str | None) -> datetime | None:
    """ISO 8601（末尾Z可）の日時を、UTCのdatetimeにする。失敗時はNone。"""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def fmt_jst(dt: datetime | None) -> str:
    return dt.astimezone(JST).strftime("%Y-%m-%d %H:%M JST") if dt else "不明"


def read_codex() -> dict:
    """Codexの最新の rate_limits（利用率）を、ログの末尾側から探す。"""
    result: dict = {"found": False}
    if not CODEX_SESSIONS.exists():
        result["reason"] = "セッションフォルダが無い"
        return result

    files = sorted(CODEX_SESSIONS.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    latest: tuple[datetime, dict] | None = None
    for path in files[:60]:  # 新しいファイルから見る（全件は不要）
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"rate_limits":{' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rl = (obj.get("payload") or {}).get("rate_limits")
                ts = parse_ts(obj.get("timestamp"))
                if not rl or ts is None:
                    continue
                if latest is None or ts > latest[0]:
                    latest = (ts, rl)
        if latest and (datetime.now(timezone.utc) - latest[0]) < timedelta(days=1):
            break  # 直近1日以内に見つかれば十分

    if latest is None:
        result["reason"] = "rate_limits（利用率）の記録が見つからない"
        return result

    ts, rl = latest
    primary = rl.get("primary") or {}
    resets = primary.get("resets_at")
    result.update(
        found=True,
        observed_at=fmt_jst(ts),
        plan_type=rl.get("plan_type"),
        used_percent=primary.get("used_percent"),
        window_minutes=primary.get("window_minutes"),
        resets_at=fmt_jst(datetime.fromtimestamp(resets, timezone.utc)) if resets else "不明",
        rate_limit_reached_type=rl.get("rate_limit_reached_type"),
        note="ローカル記録の最終値。ライブ値ではない",
    )
    return result


def read_claude() -> dict:
    """Claude Codeのログから、直近の使用トークン数と上限到達の記録を集計する。"""
    result: dict = {"found": False}
    if not CLAUDE_PROJECTS.exists():
        result["reason"] = "プロジェクト記録フォルダが無い"
        return result

    now = datetime.now(timezone.utc)
    windows = {"直近5時間": now - timedelta(hours=5), "直近7日": now - timedelta(days=7)}
    totals = {k: {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0, "messages": 0} for k in windows}
    seen: set[str] = set()  # 同じmessage.idは1回だけ数える（ログに重複行があるため）
    last_limit: tuple[datetime, dict] | None = None

    for path in CLAUDE_PROJECTS.rglob("*.jsonl"):
        try:
            fh = path.open(encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line and "usage_limit_reached" not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = parse_ts(obj.get("timestamp"))
                msg = obj.get("message") or {}

                # 上限到達の記録（リセット時刻がここから分かる）
                if obj.get("apiError") == "usage_limit_reached":
                    info = (obj.get("apiErrorParams") or {}).get("rate_limit_info") or {}
                    reset = info.get("resetsAt")
                    if ts and reset and (last_limit is None or ts > last_limit[0]):
                        last_limit = (ts, {"type": info.get("rateLimitType"), "resets_at": reset})

                usage = msg.get("usage")
                mid = msg.get("id")
                if not usage or ts is None or mid in seen:
                    continue
                seen.add(mid)
                for label, start in windows.items():
                    if ts >= start:
                        t = totals[label]
                        t["input"] += usage.get("input_tokens") or 0
                        t["cache_write"] += usage.get("cache_creation_input_tokens") or 0
                        t["cache_read"] += usage.get("cache_read_input_tokens") or 0
                        t["output"] += usage.get("output_tokens") or 0
                        t["messages"] += 1

    result.update(found=bool(seen), usage=totals)
    if last_limit:
        ts, lim = last_limit
        reset = lim["resets_at"]
        result["last_limit_hit"] = {
            "observed_at": fmt_jst(ts),
            "type": lim["type"],
            "resets_at": fmt_jst(datetime.fromtimestamp(reset, timezone.utc)),
        }
    else:
        result["last_limit_hit"] = None
    result["note"] = "利用率（%）はログに無い。トークン数の合計と、上限到達の記録だけ分かる"
    return result


def print_block(title: str, data: dict) -> None:
    print(f"== {title} ==")
    for key, value in data.items():
        if isinstance(value, dict) and key == "usage":
            for label, t in value.items():
                print(f"  [{label}] メッセージ{t['messages']}件 入力{t['input']} "
                      f"キャッシュ作成{t['cache_write']} キャッシュ読取{t['cache_read']} 出力{t['output']}")
        else:
            print(f"  {key}: {value}")
    print()


def main() -> int:
    # Windowsの標準出力が日本語を扱えない環境があるため、UTF-8に固定する
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        print_block("Codex", read_codex())
        print_block("Claude Code", read_claude())
    except OSError as exc:
        print(f"読み取りエラー: {type(exc).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
