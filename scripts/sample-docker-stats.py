#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import time
from pathlib import Path


UNIT_MULTIPLIERS = {
    "B": 1.0,
    "kB": 1000.0,
    "MB": 1000.0**2,
    "GB": 1000.0**3,
    "KiB": 1024.0,
    "MiB": 1024.0**2,
    "GiB": 1024.0**3,
}
SIZE_PATTERN = re.compile(r"^\s*(?P<value>[0-9.]+)\s*(?P<unit>[A-Za-z]+)\s*$")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Sample docker stats into analyzer-compatible resources CSV"
    )
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--interval-secs", type=float, default=1.0)
    parser.add_argument("containers", nargs="+")
    args = parser.parse_args()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    with args.out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["timestamp_ms", "service_name", "cpu_pct", "memory_bytes"],
        )
        writer.writeheader()
        while True:
            for row in sample_once(args.containers, start):
                writer.writerow(row)
            handle.flush()
            time.sleep(args.interval_secs)


def sample_once(containers: list[str], start: float) -> list[dict[str, str]]:
    completed = subprocess.run(
        ["docker", "stats", "--no-stream", "--format", "{{json .}}", *containers],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(0)
    timestamp_ms = (time.monotonic() - start) * 1000
    rows = []
    for line in completed.stdout.splitlines():
        if not line:
            continue
        payload = json.loads(line)
        rows.append(
            {
                "timestamp_ms": f"{timestamp_ms:.3f}",
                "service_name": str(payload["Name"]),
                "cpu_pct": parse_percent(str(payload["CPUPerc"])),
                "memory_bytes": f"{parse_memory_bytes(str(payload['MemUsage'])):.0f}",
            }
        )
    return rows


def parse_percent(value: str) -> str:
    return f"{float(value.strip().removesuffix('%')):.3f}"


def parse_memory_bytes(value: str) -> float:
    used = value.split("/", 1)[0].strip()
    match = SIZE_PATTERN.match(used)
    if match is None:
        raise ValueError(f"unsupported docker memory value: {value}")
    unit = match.group("unit")
    if unit not in UNIT_MULTIPLIERS:
        raise ValueError(f"unsupported docker memory unit: {unit}")
    return float(match.group("value")) * UNIT_MULTIPLIERS[unit]


if __name__ == "__main__":
    main()
