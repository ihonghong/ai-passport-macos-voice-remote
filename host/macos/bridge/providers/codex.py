"""Optional Codex quota and local daily-token provider."""

from __future__ import annotations

from datetime import datetime, timedelta
import glob
import json
import os
import select
import shutil
import subprocess
import time
from typing import Any

from .base import MetricSnapshot


def find_codex(executable: str | None = None) -> str | None:
    """Resolve Codex in interactive shells and minimal LaunchAgent environments."""
    resolved = executable or shutil.which("codex")
    if resolved:
        return resolved
    fallback = os.path.expanduser("~/.local/bin/codex")
    if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
        return fallback
    return None


def token_delta_for_local_day(record: dict[str, object], day: object) -> int:
    timestamp = record.get("timestamp")
    payload = record.get("payload")
    if not isinstance(timestamp, str) or not isinstance(payload, dict):
        return 0
    if record.get("type") != "event_msg" or payload.get("type") != "token_count":
        return 0
    try:
        event_day = datetime.fromisoformat(
            timestamp.replace("Z", "+00:00")
        ).astimezone().date()
    except ValueError:
        return 0
    if event_day != day:
        return 0
    info = payload.get("info")
    last = info.get("last_token_usage") if isinstance(info, dict) else None
    total = last.get("total_tokens") if isinstance(last, dict) else None
    return max(0, total) if isinstance(total, int) else 0


def read_daily_tokens(now: datetime | None = None) -> int:
    current = now.astimezone() if now is not None else datetime.now().astimezone()
    day = current.date()
    date_names = {day.isoformat(), (day - timedelta(days=1)).isoformat()}
    codex_home = os.path.expanduser(os.environ.get("CODEX_HOME", "~/.codex"))
    paths: set[str] = set()
    for date_name in date_names:
        year, month, date = date_name.split("-")
        paths.update(
            glob.glob(os.path.join(codex_home, "sessions", year, month, date, "*.jsonl"))
        )
        paths.update(
            glob.glob(
                os.path.join(
                    codex_home,
                    "archived_sessions",
                    f"rollout-{date_name}*.jsonl",
                )
            )
        )

    midnight = current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    for root in (
        os.path.join(codex_home, "sessions"),
        os.path.join(codex_home, "archived_sessions"),
    ):
        for directory, _, filenames in os.walk(root):
            for filename in filenames:
                if not filename.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, filename)
                try:
                    if os.path.getmtime(path) >= midnight:
                        paths.add(path)
                except OSError:
                    continue

    total_tokens = 0
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as session_file:
                for line in session_file:
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(record, dict):
                        total_tokens += token_delta_for_local_day(record, day)
        except OSError:
            continue
    return total_tokens


def extract_remaining(message: dict[str, object]) -> int:
    result = message.get("result")
    if not isinstance(result, dict):
        raise ValueError("Codex usage response has no result")
    buckets = result.get("rateLimitsByLimitId")
    snapshot = buckets.get("codex") if isinstance(buckets, dict) else None
    if not isinstance(snapshot, dict):
        snapshot = result.get("rateLimits")
    primary = snapshot.get("primary") if isinstance(snapshot, dict) else None
    used = primary.get("usedPercent") if isinstance(primary, dict) else None
    if not isinstance(used, int):
        raise ValueError("Codex usage response has no primary percentage")
    return max(0, min(100, 100 - used))


def read_remaining(codex: str | None = None, timeout: float = 10.0) -> int:
    executable = find_codex(codex)
    if not executable:
        raise RuntimeError("Codex CLI not found")

    process = subprocess.Popen(
        (executable, "app-server", "--stdio"),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        assert process.stdin is not None
        assert process.stdout is not None
        requests = (
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "ai-passport-bridge",
                        "title": "AI Passport Bridge",
                        "version": "0.2.0",
                    }
                },
            },
            {"method": "initialized", "params": {}},
            {"id": 2, "method": "account/rateLimits/read", "params": {}},
        )
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            wait = min(0.25, deadline - time.monotonic())
            readable, _, _ = select.select([process.stdout], [], [], wait)
            if not readable:
                continue
            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") == 2:
                return extract_remaining(message)
        raise TimeoutError("Codex usage request timed out")
    finally:
        process.terminate()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1.0)


class CodexProvider:
    name = "codex"

    def __init__(self, settings: dict[str, Any]) -> None:
        self.refresh_seconds = float(settings.get("refresh_seconds", 300))
        self._codex_path = settings.get("executable")
        self._timeout = float(settings.get("timeout_seconds", 10))

    def read(self) -> MetricSnapshot:
        return MetricSnapshot(
            provider=self.name,
            remaining_percent=read_remaining(self._codex_path, self._timeout),
            daily_total=read_daily_tokens(),
        )


def create(settings: dict[str, Any]) -> CodexProvider:
    return CodexProvider(settings)
