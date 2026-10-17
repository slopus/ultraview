#!/usr/bin/env python3
"""Check the demo's -perfRun YES console output against a frame budget."""

import argparse
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--simulator", action="store_true", help="Use simulator regression budgets (200 ms lifecycle, 50 ms app turns)")
    parser.add_argument("--require-background", action="store_true")
    parser.add_argument("--one-frame", action="store_true", help="Check the aspirational one-frame benchmark instead of regression budgets")
    args = parser.parse_args()
    lines = [line.partition("PERF-RESULT ")[2] for line in args.log.read_text().splitlines() if "PERF-RESULT " in line]
    if not lines:
        parser.exit(1, "No completed PERF-RESULT report found\n")
    report = json.loads(lines[-1])
    failures = []
    if report["configuration"] != "Release":
        failures.append("Performance checks require a Release build")
    if report.get("mainThreadWork") != 0:
        failures.append("Expected zero main-thread layout, text and drawing operations")
    hosts = report.get("hosts", {})
    if set(hosts) != {"layout", "feed", "stress"}:
        failures.append("Expected application statistics for all three node hosts")
    for name, host in hosts.items():
        maximum = host.get("maxApplyMs", math.nan)
        if not math.isfinite(maximum) or maximum < 0 or maximum > 50:
            failures.append(f"{name}: applying library commits exceeded 50 ms ({maximum})")
    required = {
        "launch", "first feed", "first stress", "first layout again", "tab switches",
        "rapid tab switches", "feed fling down", "feed fling up", "feed jumps",
        "stress", "rotation", "idle",
    }
    if args.require_background:
        required.update({"background", "return from background"})
    phases = report["phases"]
    missing = required - {phase["phase"] for phase in phases}
    if missing:
        failures.append("Missing phases: " + ", ".join(sorted(missing)))
    budgets = {
        "launch": 200, "first feed": 50, "tab switches": 1000 / 30,
        "rapid tab switches": 25, "feed jumps": 1000 / 30,
        "rotation": 1000 / 15, "background": 50, "return from background": 200,
    }
    for phase in phases:
        budget = 1000 / 60 if args.one_frame or not args.simulator else 50.0
        if args.simulator and not args.one_frame and phase["phase"] in {"launch", "return from background"}:
            budget = 200.0
        if not args.simulator and not args.one_frame:
            budget = budgets.get(phase["phase"], budget)
        maximum = phase["maxTurnMs"]
        if maximum > 1000 / 60:
            print(f"FRAME OVERRUN {phase['phase']}: {maximum:.2f} ms")
        if not math.isfinite(maximum) or maximum < 0 or maximum > budget:
            failures.append(f"{phase['phase']}: {maximum:.2f} ms exceeds {budget:.2f} ms")
    for failure in failures:
        print(f"FAIL {failure}")
    if failures:
        return 1
    mode = "one-frame benchmark" if args.one_frame else "regression budgets"
    print(f"PASS {len(phases)} phases within {mode}; library application <=50 ms; zero main-thread layout/text/draw")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())