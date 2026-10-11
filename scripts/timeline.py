#!/usr/bin/env python3
"""
Lines up what the users saw (load test) with what the cluster did (watch-cluster.sh).

Reads:  results/<name>.csv, results/<name>.meta.json, results/<name>-cluster.log
Prints: one timeline, in seconds since the load test started, e.g.

    20.0s  EVENT START: aws ec2 stop-instances ...
    21.3s  first failed request
    62.4s  NODES master=Ready worker1=Ready worker2=NotReady
    62.9s  ENDPOINTS 10.42.1.5@worker1
    63.0s  last failed request

Usage: python3 scripts/timeline.py e3-node-down
"""
import csv
import json
import os
import sys
from collections import Counter

SLOW_MS = 900  # slower than this = Nginx probably waited for a dead worker, then retried


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    name = sys.argv[1]
    base = os.path.join("results", name)
    meta = json.load(open(base + ".meta.json"))
    start = meta["start_epoch"]

    rows = []
    with open(base + ".csv") as f:
        for r in csv.DictReader(f):
            rows.append((float(r["t_offset_s"]), r["ok"] == "1", float(r["latency_ms"]), r.get("error", "")))

    lines = [(e["t_offset_s"], e["message"]) for e in meta["events"]]

    failed = [r for r in rows if not r[1]]
    slow = [r for r in rows if r[1] and r[2] > SLOW_MS]
    if failed:
        lines.append((failed[0][0], f"first failed request ({failed[0][3]})"))
        lines.append((failed[-1][0], f"last failed request ({failed[-1][3]})"))
    if slow:
        lines.append((slow[0][0], f"first slow request (> {SLOW_MS} ms, likely retried by Nginx)"))
        lines.append((slow[-1][0], f"last slow request"))

    cluster_log = base + "-cluster.log"
    if os.path.exists(cluster_log):
        for raw in open(cluster_log):
            parts = raw.strip().split(" ", 1)
            if len(parts) == 2:
                try:
                    t = float(parts[0]) - start
                except ValueError:
                    continue
                if t >= 0:
                    lines.append((t, parts[1]))
    else:
        print(f"(no {cluster_log}: cluster events not shown)")

    print(f"Timeline for {name} (seconds since load test start)\n")
    for t, msg in sorted(lines, key=lambda x: x[0]):
        print(f"{t:7.1f}s  {msg}")

    total = len(rows)
    print("\nSummary")
    print(f"  requests            : {total}")
    print(f"  failed              : {len(failed)}")
    for e, n in Counter(r[3] for r in failed).most_common():
        print(f"    {e:<18}: {n}")
    print(f"  slow (> {SLOW_MS} ms)     : {len(slow)}")
    if failed:
        print(f"  error window        : {failed[0][0]:.1f}s to {failed[-1][0]:.1f}s "
              f"({failed[-1][0] - failed[0][0]:.1f} s)")


if __name__ == "__main__":
    main()
