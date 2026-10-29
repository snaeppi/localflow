"""Build a dictation-like English test set from the Open ASR Leaderboard test splits.

Samples clips of 2-25 s (typical push-to-talk length, and within every candidate
model's single-window limit) from several conditions and writes 16 kHz mono WAVs
plus a manifest.jsonl. Only the needed parquet row groups are fetched.

usage: python bench/build_testset.py OUT_DIR [--per-subset 70]
"""
import argparse, io, json, random, sys
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
import soxr
from huggingface_hub import HfFileSystem

REPO = "datasets/hf-audio/open-asr-leaderboard@de79e57adf9983993bcc72586d7313460825f5eb"
SUBSETS = {
    # name: glob within repo
    "common_voice": "common_voice/test-*.parquet",
    "librispeech_other": "librispeech/test.other-*.parquet",
    "voxpopuli": "voxpopuli/test-*.parquet",
    "gigaspeech": "gigaspeech/test-*.parquet",
    "earnings22": "earnings22/test-*.parquet",
    "ami": "ami/test-*.parquet",
}
MIN_S, MAX_S = 2.0, 25.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--per-subset", type=int, default=70)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    out = Path(args.out)
    (out / "audio").mkdir(parents=True, exist_ok=True)
    fs = HfFileSystem()
    rng = random.Random(args.seed)
    manifest = []
    for name, pattern in SUBSETS.items():
        files = sorted(fs.glob(f"{REPO}/{pattern}"))
        # Index (file, row_group, row) for every clip in range, reading only the length column.
        candidates = []
        handles = {}
        for f in files:
            fh = fs.open(f, block_size=1 << 20)
            pf = pq.ParquetFile(fh)
            handles[f] = pf
            for rg in range(pf.metadata.num_row_groups):
                lens = pf.read_row_group(rg, columns=["audio_length_s"]).column(0).to_pylist()
                candidates += [(f, rg, i) for i, s in enumerate(lens) if MIN_S <= s <= MAX_S]
        picks = sorted(rng.sample(candidates, min(args.per_subset, len(candidates))))
        by_group = {}
        for f, rg, i in picks:
            by_group.setdefault((f, rg), []).append(i)
        n = 0
        for (f, rg), rows in by_group.items():
            t = handles[f].read_row_group(rg, columns=["audio", "text", "id", "audio_length_s"])
            for i in rows:
                r = t.slice(i, 1).to_pylist()[0]
                audio, sr = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
                if audio.ndim > 1:
                    audio = audio.mean(axis=1)
                if sr != 16000:
                    audio = soxr.resample(audio, sr, 16000, quality="VHQ").astype(np.float32)
                if not r["text"].strip():
                    continue
                uid = f"{name}-{n:03d}"
                sf.write(out / "audio" / f"{uid}.wav", audio, 16000, subtype="PCM_16")
                manifest.append({"id": uid, "subset": name, "audio": f"audio/{uid}.wav",
                                 "duration": round(len(audio) / 16000, 3), "text": r["text"]})
                n += 1
        print(f"{name}: {n} clips from {len(candidates)} candidates", file=sys.stderr)
    with open(out / "manifest.jsonl", "w") as fh:
        for m in manifest:
            fh.write(json.dumps(m) + "\n")
    total = sum(m["duration"] for m in manifest)
    print(f"total {len(manifest)} clips, {total/60:.1f} min", file=sys.stderr)


if __name__ == "__main__":
    main()
