"""Score benchmark runs against the test-set manifest.

Normalized WER uses the Whisper English normalizer (same as the Open ASR Leaderboard), or Whisper's
basic normalizer for clips whose manifest `language` isn't English (build_multilingual_testset.py),
pooled per subset. "PnC WER" is computed on the subsets whose references keep punctuation and casing
(Common Voice, FLEURS, user*) with whitespace tokenization, so it also counts formatting errors a
dictation user would have to fix by hand.

usage: python bench/score.py MANIFEST RESULTS_DIR [engine ...]
"""
import json, re, statistics, sys
from pathlib import Path

import jiwer
from whisper_normalizer.basic import BasicTextNormalizer
from whisper_normalizer.english import EnglishTextNormalizer

english, basic = EnglishTextNormalizer(), BasicTextNormalizer()


def norm(text, clip):
    return english(text) if clip.get("language", "en") == "en" else basic(text)


def keeps_formatting(subset):
    return subset in ("common_voice",) or subset.startswith(("cv-", "fleurs-", "user"))


def pnc(s):
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"\s+", " ", s).strip()


def wer(refs, hyps):
    pairs = [(r, h) for r, h in zip(refs, hyps) if r.strip()]
    if not pairs:
        return float("nan")
    refs, hyps = zip(*pairs)
    return 100 * jiwer.wer(list(refs), [h if h.strip() else "<empty>" for h in hyps])


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def main():
    manifest = {}
    for line in open(sys.argv[1]):
        m = json.loads(line)
        manifest[m["id"]] = m
    results_dir = Path(sys.argv[2])
    engines = sys.argv[3:] or sorted(
        p.name[: -len(".summary.json")] for p in results_dir.glob("*.summary.json"))
    subsets = sorted({m["subset"] for m in manifest.values()})
    rows = []
    for engine in engines:
        hyps = {}
        for line in open(results_dir / f"{engine}.jsonl"):
            r = json.loads(line)
            hyps[r["id"]] = r
        summary = json.loads((results_dir / f"{engine}.summary.json").read_text())
        row = {"engine": engine, **{k: summary.get(k) for k in ("load_ms", "first_ms", "rtfx", "footprint_peak_mb", "mlx_peak_mb")}}
        per = {}
        for s in subsets:
            ids = [i for i, m in manifest.items() if m["subset"] == s and i in hyps]
            per[s] = wer([norm(manifest[i]["text"], manifest[i]) for i in ids], [norm(hyps[i]["hyp"], manifest[i]) for i in ids])
        row["wer"] = per
        row["wer_avg"] = statistics.mean(per.values())
        # References with punctuation and casing: Common Voice, FLEURS and your own read script.
        cv = [i for i, m in manifest.items() if keeps_formatting(m["subset"]) and i in hyps]
        row["pnc_wer_cv"] = wer([pnc(manifest[i]["text"]) for i in cv], [pnc(hyps[i]["hyp"]) for i in cv])
        ms = [hyps[i]["ms"] for i in hyps]
        row["p50_ms"], row["p90_ms"], row["max_ms"] = pct(ms, 0.5), pct(ms, 0.9), max(ms)
        for lo, hi in ((0, 5), (5, 10), (10, 30)):
            b = [hyps[i]["ms"] for i in hyps if lo <= manifest[i]["duration"] < hi]
            row[f"p50_ms_{lo}-{hi}s"] = statistics.median(b) if b else None
        row["missing"] = len(manifest) - len(hyps)
        rows.append(row)

    short = {"common_voice": "CV", "librispeech_other": "LS-o", "voxpopuli": "VoxP", "gigaspeech": "Giga", "earnings22": "Earn", "ami": "AMI"}
    head = ["engine", "avg WER"] + [short.get(s, s) for s in subsets] + ["PnC", "p50 ms", "p50 ≤5s", "p50 5-10s", "p50 10-25s", "p90 ms", "load ms", "1st ms", "RTFx", "peak MB"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for r in sorted(rows, key=lambda r: r["wer_avg"]):
        f = lambda x, d=1: "–" if x is None else f"{x:.{d}f}"
        mem = r["footprint_peak_mb"] if not r.get("mlx_peak_mb") else max(r["footprint_peak_mb"] or 0, r["mlx_peak_mb"])
        cells = [r["engine"], f(r["wer_avg"], 2)] + [f(r["wer"][s], 2) for s in subsets] + [
            f(r["pnc_wer_cv"], 2), f(r["p50_ms"], 0), f(r["p50_ms_0-5s"], 0), f(r["p50_ms_5-10s"], 0), f(r["p50_ms_10-30s"], 0),
            f(r["p90_ms"], 0), f(r["load_ms"], 0), f(r["first_ms"], 0), f(r["rtfx"], 0), f(mem, 0)]
        print("| " + " | ".join(cells) + " |")
        if r["missing"]:
            print(f"  ({r['engine']}: {r['missing']} clips missing)")
    (results_dir / "scores.json").write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
