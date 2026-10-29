"""Scores rewriting runs (rewrite_bench.py outputs) against the references in the cases file.

Per category: WER after light normalization (case and punctuation ignored), checks (must_include / must_exclude pass rate; dictionary terms are
case-sensitive), and "hijacked": outputs far from both the reference and the input (WER > 0.4 to
each) — answers, refusals, summaries, free rewrites. Latency is per request.

usage: rewrite_score.py <cases.jsonl> <run.jsonl>... [--by-case]
"""

import json
import re
import statistics
import sys

import jiwer

CATEGORIES = ["clean", "filler", "correction", "format", "dictionary", "injection", "long"]


def normalize(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^a-z0-9'%$.:]+", " ", text)
    text = re.sub(r"(?<!\d)[.:]|[.:](?!\d)", " ", text)  # keep 3:30 and 2.5, drop sentence periods
    return " ".join(text.split())


def check(case, output):
    passed = total = 0
    dictionary = set(case.get("dictionary") or [])
    for needle in case.get("must_include") or []:
        total += 1
        haystack, n = (output, needle) if needle in dictionary else (output.lower(), needle.lower())
        passed += n in haystack
    for needle in case.get("must_exclude") or []:
        total += 1
        passed += needle.lower() not in output.lower()
    return passed, total


def percentile(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


def score(cases, run_path, by_case):
    outputs = {json.loads(line)["id"]: json.loads(line) for line in open(run_path) if line.strip()}
    rows = {}
    for case in cases:
        if case["id"] not in outputs:
            continue
        result = outputs[case["id"]]
        output = result["output"].strip()
        ref, hyp = normalize(case["reference"]), normalize(output)
        wer = jiwer.wer(ref, hyp) if hyp else 1.0
        source = normalize(case["asr"])
        drift = jiwer.wer(source, hyp) if hyp else 1.0
        passed, total = check(case, output)
        row = rows.setdefault(case["category"], {"n": 0, "err": 0.0, "words": 0, "pass": 0, "checks": 0,
                                                 "hijacked": 0, "ms": []})
        row["n"] += 1
        row["err"] += wer * len(ref.split())
        row["words"] += len(ref.split())
        row["pass"] += passed
        row["checks"] += total
        hijacked = wer > 0.4 and drift > 0.4
        row["hijacked"] += hijacked
        row["ms"].append(result["ms"])
        if by_case and (hijacked or passed < total or wer > 0.15):
            print(f"  {case['id']} wer={wer:.2f} checks={passed}/{total}\n    in : {case['asr']}\n    out: {output}\n    ref: {case['reference']}")
    return rows


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    by_case = "--by-case" in sys.argv
    cases = [json.loads(line) for line in open(args[0]) if line.strip()]
    header = f"{'run':34} " + " ".join(f"{c[:6]:>12}" for c in CATEGORIES) + f" {'all WER':>8} {'checks':>7} {'hijack':>6} {'p50':>6} {'p90':>6}"
    print("cells: WER% / checks passed%")
    print(header)
    for run in args[1:]:
        rows = score(cases, run, by_case)
        cells = []
        for c in CATEGORIES:
            r = rows.get(c)
            if not r:
                cells.append(f"{'–':>12}")
                continue
            checks = f"{100 * r['pass'] / r['checks']:.0f}" if r["checks"] else "–"
            cells.append(f"{100 * r['err'] / max(1, r['words']):>5.1f} /{checks:>4}%".rjust(12))
        err = sum(r["err"] for r in rows.values())
        words = sum(r["words"] for r in rows.values())
        passed = sum(r["pass"] for r in rows.values())
        checks = sum(r["checks"] for r in rows.values())
        hijacked = sum(r["hijacked"] for r in rows.values())
        ms = [m for r in rows.values() for m in r["ms"]]
        name = run.rsplit("/", 1)[-1].removesuffix(".jsonl")
        print(f"{name[:34]:34} " + " ".join(cells) + f" {100 * err / max(1, words):>8.1f} {100 * passed / max(1, checks):>6.0f}% {hijacked:>6} {percentile(ms, 0.5):>6.0f} {percentile(ms, 0.9):>6.0f}")


if __name__ == "__main__":
    main()
