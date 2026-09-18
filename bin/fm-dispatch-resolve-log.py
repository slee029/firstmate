#!/usr/bin/env python3
import datetime
import hashlib
import json
import os
import sys


def profile(value):
    if not isinstance(value, dict):
        return None
    return {key: value[key] for key in ("harness", "model", "effort", "provider") if key in value}


def main():
    path, brief, status, reason, latency, valid, response_path = sys.argv[1:]
    raw = sys.stdin.read().strip()
    result = json.loads(raw) if raw else {}
    response = {}
    if valid == "true":
        with open(response_path, encoding="utf-8") as stream:
            response = json.load(stream)
    answer = response.get("answers", {}).get("rule", {})
    usage = response.get("usage", {})
    status = result.get("status", status)
    entry = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "brief_path_hash": hashlib.sha256(os.fsencode(brief)).hexdigest() if brief else None,
        "status": status,
        "reason": result.get("reason", "profile selected" if status == "clear" else reason),
        "rule": result.get("rule", answer.get("choice")),
        "confidence": result.get("confidence", answer.get("confidence")),
        "model": result.get("model", response.get("model")),
        "latency_ms": json.loads(latency),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "selected_profile": profile(result.get("chosen", {}).get("profile")),
        "skipped_candidates": [
            {"profile": profile(candidate.get("profile")),
             "reason": candidate.get("reason"), "resetsAt": candidate.get("resetsAt", [])}
            for candidate in result.get("skipped_candidates", [])
        ],
        "intake": "clear" if status == "clear" else "fallback",
    }
    line = (json.dumps(entry, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if os.write(fd, line) != len(line):
            raise OSError("incomplete evidence append")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
