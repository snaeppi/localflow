"""Summarizes an end-to-end run: Localflow's timing log, and key release to text in TextTarget.

usage: summarize.py RUN_DIR
"""
import json
import re
import sys
from pathlib import Path

run = Path(sys.argv[1])
FIELDS = ["audio", "mic start", "release→captured", "processing", "asr", "text", "release→paste"]


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, round(p / 100 * (len(s) - 1)))]


def stats(values):
    return (f"p50 {pct(values, 50):5.0f}  p90 {pct(values, 90):5.0f}  mean {sum(values) / len(values):5.1f}  "
            f"max {max(values):5.0f}")


timings = []
for line in open(run / "localflow.ndjson"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("category") != "dictation" or "release→paste" not in event.get("eventMessage", ""):
        continue
    message = event["eventMessage"]
    timings.append({f: float(re.search(re.escape(f) + r" ([\d.]+)", message).group(1)) for f in FIELDS})

offset = 0
summary = {}
for name in ("on", "off"):
    driver_file = run / f"driver-{name}.jsonl"
    if not driver_file.exists():
        continue
    driver = [json.loads(line) for line in open(driver_file)]
    target = [json.loads(line) for line in open(run / f"target-{name}.jsonl")]
    app = timings[offset:offset + len(driver)]
    offset += len(driver)
    assert len(target) == len(driver) == len(app), (name, len(driver), len(target), len(app))
    keep = [i for i, d in enumerate(driver) if not d["warmup"]]
    external = [(target[i]["t"] - driver[i]["released"]) / 1e6 for i in keep]
    rows = [app[i] for i in keep]
    print(f"cleanup {name}: {len(keep)} dictations, audio {min(r['audio'] for r in rows)}–{max(r['audio'] for r in rows)} s")
    print(f"  key up → text in field  {stats(external)}")
    for f in FIELDS[2:]:
        print(f"  {f:22s}  {stats([r[f] for r in rows])}")
    tails = sum(r["release→captured"] > 100 for r in rows)
    print(f"  release tail recorded: {tails}")
    summary[name] = {"external": external, "app": rows}
json.dump(summary, open(run / "summary.json", "w"))
