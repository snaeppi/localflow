"""Build a multilingual test set from Common Voice 17 and FLEURS for benchmarking Parakeet TDT v3.

Samples clips of 2-25 s (typical push-to-talk length, and within the model's single-window limit)
from the Common Voice 17 test split and from the FLEURS test split of each language, and writes
16 kHz mono WAVs plus a manifest.jsonl. References keep case and punctuation; scorers normalize.
Both datasets are pinned to a revision. Only the needed parquet row groups are fetched, and the
FLEURS archives are streamed and never stored.

usage: python bench/build_multilingual_testset.py OUT_DIR [--per-source 30] [--seed 7]
                                                  [--languages sv,fi,de,fr,es,pl,ru]
"""
import argparse, io, json, random, sys, tarfile, time
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
import soxr
from huggingface_hub import HfFileSystem

CV_REPO = "datasets/fixie-ai/common_voice_17_0@34f78a43893414e7b6e271ba94c1d5e05f18b239"
FLEURS_REPO = "datasets/google/fleurs@70bb2e84b976b7e960aa89f1c648e09c59f894dd"
# ISO code -> (Common Voice directory, FLEURS directory); None where a corpus lacks the language.
# Swedish is "sv-SE" in Common Voice, Spanish is Latin American ("es_419") in FLEURS.
LANGUAGES = {
    "bg": ("bg", "bg_bg"), "cs": ("cs", "cs_cz"), "da": ("da", "da_dk"), "de": ("de", "de_de"),
    "el": ("el", "el_gr"), "en": ("en", "en_us"), "es": ("es", "es_419"), "et": ("et", "et_ee"),
    "fi": ("fi", "fi_fi"), "fr": ("fr", "fr_fr"), "hr": (None, "hr_hr"), "hu": ("hu", "hu_hu"),
    "it": ("it", "it_it"), "lt": ("lt", "lt_lt"), "lv": ("lv", "lv_lv"), "mt": (None, "mt_mt"),
    "nl": ("nl", "nl_nl"), "pl": ("pl", "pl_pl"), "pt": ("pt", "pt_br"), "ro": ("ro", "ro_ro"),
    "ru": ("ru", "ru_ru"), "sk": ("sk", "sk_sk"), "sl": ("sl", "sl_si"), "sv": ("sv-SE", "sv_se"),
    "uk": ("uk", "uk_ua"),
}
MIN_S, MAX_S = 2.0, 25.0
SR = 16000


def retry(fn, attempts=3):
    for k in range(attempts):
        try:
            return fn()
        except Exception as e:  # network errors come from fsspec, aiohttp and huggingface_hub alike
            if k == attempts - 1:
                raise
            print(f"  retrying after {type(e).__name__}: {e}", file=sys.stderr)
            time.sleep(2 * (k + 1))


def to_16k(data):
    """Decode an audio file's bytes (MP3 or WAV) to mono float32 at 16 kHz."""
    audio, sr = sf.read(io.BytesIO(data), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SR:
        audio = soxr.resample(audio, sr, SR, quality="VHQ").astype(np.float32)
    return audio


def common_voice(fs, directory, n, rng):
    """n random test clips as [(audio, sentence)]. The parquet files have no duration column, so
    candidates are decoded in random order until n fit MIN_S-MAX_S."""
    files = sorted(set(fs.glob(f"{CV_REPO}/{directory}/test-*.parquet")
                       + fs.glob(f"{CV_REPO}/{directory}/test/**/*.parquet")))
    handles = {f: pq.ParquetFile(fs.open(f, block_size=1 << 20)) for f in files}
    rows = [(f, rg, i) for f, pf in handles.items() for rg in range(pf.metadata.num_row_groups)
            for i in range(pf.metadata.row_group(rg).num_rows)]
    rng.shuffle(rows)
    picked, seen, used, rejected = {}, set(), 0, 0
    while len(picked) < n and used < len(rows):
        batch = rows[used:used + max(8, (n - len(picked)) * 5 // 4)]
        used += len(batch)
        by_group = {}
        for f, rg, i in batch:
            by_group.setdefault((f, rg), []).append(i)
        clips = {}
        for (f, rg), idx in by_group.items():
            t = retry(lambda: handles[f].read_row_group(rg, columns=["audio", "sentence"]).take(idx))
            for i, r in zip(idx, t.to_pylist()):
                clips[(f, rg, i)] = r
        for key in batch:  # in random order, so the first n that pass are a random sample
            if len(picked) == n:
                break
            r = clips[key]
            text = r["sentence"]
            if not text.strip() or text.strip() in seen:
                continue
            try:
                audio = to_16k(r["audio"]["bytes"])
            except RuntimeError as e:  # soundfile's errors
                print(f"  undecodable clip skipped: {e}", file=sys.stderr)
                continue
            if not MIN_S <= len(audio) / SR <= MAX_S:
                rejected += 1
                continue
            seen.add(text.strip())
            picked[key] = (audio, text)
    print(f"  {len(rows)} test clips, decoded {used} candidates, {rejected} outside "
          f"{MIN_S:g}-{MAX_S:g} s", file=sys.stderr)
    return [picked[k] for k in sorted(picked)]  # dataset order, so ids are stable


def fleurs_rows(fs, directory):
    """Rows of data/<code>/test.tsv, which has no header: sentence id, file name, raw
    transcription, normalized transcription, characters, num_samples (16 kHz), gender."""
    rows = [line.split("\t") for line in fs.read_text(f"{FLEURS_REPO}/data/{directory}/test.tsv").split("\n")
            if line]
    assert all(len(r) == 7 for r in rows), f"{directory}: unexpected TSV layout"

    def wrapped(field):  # "..." with "" inside, as a CSV writer quotes a field that holds a quote
        return len(field) >= 2 and field[0] == field[-1] == '"' and '"' not in field[1:-1].replace('""', '')

    # de, fr and sv quote every field with a quote CSV style; fi and ru hold bare quotes, and there
    # a leading quote is part of the sentence. Unwrap only when no field contradicts the CSV style.
    unwrapped = 0
    if all(wrapped(r[2]) for r in rows if '"' in r[2]):
        for r in rows:
            if wrapped(r[2]):
                r[2] = r[2][1:-1].replace('""', '"')
                unwrapped += 1
    print(f"  {len(rows)} test recordings, {unwrapped} CSV-quoted transcriptions unwrapped", file=sys.stderr)
    return rows


def fleurs(fs, directory, n, rng):
    """n random test clips as [(audio, raw transcription)], at most one recording per sentence."""
    by_id = {}
    for sid, name, raw, _normalized, _chars, samples, _gender in fleurs_rows(fs, directory):
        if MIN_S * SR <= int(samples) <= MAX_S * SR and raw.strip():
            by_id.setdefault(sid, []).append((name, raw))
    ids = sorted(by_id)
    rng.shuffle(ids)
    picks, seen = {}, set()
    for sid in ids:
        name, raw = rng.choice(sorted(by_id[sid]))
        if raw in seen:
            continue
        seen.add(raw)
        picks[name] = raw
        if len(picks) == n:
            break

    def stream():  # the archive is read once, front to back, and only the picked files are kept
        found = {}
        with fs.open(f"{FLEURS_REPO}/data/{directory}/audio/test.tar.gz", block_size=16 << 20) as fh:
            with tarfile.open(fileobj=fh, mode="r|gz") as tar:
                for member in tar:
                    name = member.name.rsplit("/", 1)[-1]
                    if name in picks:
                        found[name] = to_16k(tar.extractfile(member).read())
                        if len(found) == len(picks):
                            break
        return found

    found = retry(stream)
    if len(found) < len(picks):
        print(f"  {len(picks) - len(found)} picked files missing from the archive", file=sys.stderr)
    clips = []
    for name in sorted(found):
        if not MIN_S <= len(found[name]) / SR <= MAX_S:
            print(f"  {name} is {len(found[name]) / SR:.2f} s, not as in the TSV; skipped", file=sys.stderr)
            continue
        clips.append((found[name], picks[name]))
    return clips


def write_manifest(out, manifest):
    with open(out / "manifest.jsonl", "w", encoding="utf-8") as fh:
        for m in manifest:
            fh.write(json.dumps(m, ensure_ascii=False) + "\n")


def summarize(manifest):
    groups = {}
    for m in manifest:
        groups.setdefault(m["subset"], []).append(m["duration"])
    for subset, d in groups.items():
        print(f"{subset}: {len(d)} clips, {sum(d) / 60:.1f} min", file=sys.stderr)
    for source in ("cv", "fleurs"):
        d = [m["duration"] for m in manifest if m["subset"].split("-")[0] == source]
        if d:
            print(f"{source}: {len(d)} clips, {sum(d) / 60:.1f} min, duration mean {np.mean(d):.1f} s, "
                  f"min {min(d):.1f} s, max {max(d):.1f} s, {sum(x > 15 for x in d)} over 15 s", file=sys.stderr)
    total = sum(m["duration"] for m in manifest)
    print(f"total {len(manifest)} clips, {total / 60:.1f} min", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--per-source", type=int, default=30)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--languages", default="sv,fi,de,fr,es,pl,ru")
    args = ap.parse_args()
    languages = args.languages.split(",")
    unknown = [l for l in languages if l not in LANGUAGES]
    if unknown:
        ap.error(f"unknown languages {unknown}; choose from {','.join(LANGUAGES)}")
    out = Path(args.out)
    (out / "audio").mkdir(parents=True, exist_ok=True)
    fs = HfFileSystem()
    manifest = []
    for lang in languages:
        cv_dir, fleurs_dir = LANGUAGES[lang]
        for source, directory, pick in (("cv", cv_dir, common_voice), ("fleurs", fleurs_dir, fleurs)):
            subset = f"{source}-{lang}"
            if directory is None:
                print(f"{subset}: no such split, skipped", file=sys.stderr)
                continue
            print(f"{subset}:", file=sys.stderr)
            t0 = time.time()
            # One generator per subset, so a subset's clips don't depend on which others are built.
            clips = pick(fs, directory, args.per_source, random.Random(f"{args.seed}/{subset}"))
            if len(clips) < args.per_source:
                print(f"  only {len(clips)} of {args.per_source} clips found", file=sys.stderr)
            for n, (audio, text) in enumerate(clips):
                uid = f"{subset}-{n:03d}"
                sf.write(out / "audio" / f"{uid}.wav", np.clip(audio, -1.0, 1.0), SR, subtype="PCM_16")
                manifest.append({"id": uid, "subset": subset, "language": lang, "audio": f"audio/{uid}.wav",
                                 "duration": round(len(audio) / SR, 3), "text": text})
            print(f"  {len(clips)} clips in {time.time() - t0:.0f} s", file=sys.stderr)
        write_manifest(out, manifest)  # after each language, so a failure keeps the finished ones
    summarize(manifest)


if __name__ == "__main__":
    main()
