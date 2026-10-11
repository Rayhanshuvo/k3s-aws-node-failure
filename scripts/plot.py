#!/usr/bin/env python3
"""
Draws successful and failed requests per second for one or more runs, one panel per run.

Usage: python3 scripts/plot.py e3-node-down e4-resilient-node-down -o screenshots/node-failure.png
Needs matplotlib:  pip install matplotlib
"""
import argparse
import csv
import json
import os
from collections import Counter

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


def load(name):
    ok, err = Counter(), Counter()
    with open(os.path.join("results", f"{name}.csv")) as f:
        for r in csv.DictReader(f):
            sec = int(float(r["t_offset_s"]))
            (ok if r["ok"] == "1" else err)[sec] += 1
    meta = json.load(open(os.path.join("results", f"{name}.meta.json")))
    events = [e["t_offset_s"] for e in meta["events"] if e["message"].startswith("EVENT START")]
    last = max(list(ok) + list(err) + [0])
    secs = list(range(last + 1))
    return secs, [ok[s] for s in secs], [err[s] for s in secs], events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("-o", "--out", default="screenshots/node-failure.png")
    args = ap.parse_args()

    fig, axes = plt.subplots(len(args.runs), 1, figsize=(10, 2.6 * len(args.runs)), sharex=True, squeeze=False)
    for ax, name in zip(axes[:, 0], args.runs):
        secs, ok, err, events = load(name)
        ax.plot(secs, ok, color="#2f6fe4", lw=1.6, label="successful")
        ax.bar(secs, err, color="#d64545", width=1.0, label="failed")
        for t in events:
            ax.axvline(t, color="#555", ls="--", lw=1)
            ax.text(t + 1, ax.get_ylim()[1] * 0.9, "worker2 stopped", fontsize=8, color="#555")
        ax.set_title(f"{name}: {sum(err)} failed of {sum(ok) + sum(err)}", loc="left", fontsize=10)
        ax.set_ylabel("req/s")
        ax.spines[["top", "right"]].set_visible(False)
    axes[0, 0].legend(loc="lower right", frameon=False, fontsize=8)
    axes[-1, 0].set_xlabel("seconds")
    fig.tight_layout()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    fig.savefig(args.out, dpi=150)
    print(f"saved {args.out}")


if __name__ == "__main__":
    main()
