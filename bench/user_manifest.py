"""Pair saved Localflow recordings with the sentences that were read, for scoring models on
your own voice.

Turn on Advanced settings › Save recordings, dictate the lines of bench/dictation_script.txt in order
(one press per line), then:

usage: python bench/user_manifest.py RECORDINGS_DIR SCRIPT.txt SUBSET OUT_DIR [--skip N]
  Uses the newest len(script) recordings (after skipping the newest N) in chronological order.
"""
import json, shutil, sys, wave
from pathlib import Path

recordings, script, subset, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
skip = int(sys.argv[sys.argv.index("--skip") + 1]) if "--skip" in sys.argv else 0
lines = [l.strip() for l in script.read_text().splitlines() if l.strip()]
wavs = sorted(recordings.glob("*.wav"))
wavs = wavs[: len(wavs) - skip] if skip else wavs
wavs = wavs[-len(lines):]
assert len(wavs) == len(lines), f"need {len(lines)} recordings, found {len(wavs)}"
(out / "audio").mkdir(parents=True, exist_ok=True)
with open(out / "manifest.jsonl", "a") as fh:
    for i, (wav, text) in enumerate(zip(wavs, lines)):
        uid = f"{subset}-{i:02d}"
        shutil.copy(wav, out / "audio" / f"{uid}.wav")
        with wave.open(str(wav)) as w:
            duration = w.getnframes() / w.getframerate()
        fh.write(json.dumps({"id": uid, "subset": subset, "audio": f"audio/{uid}.wav", "duration": round(duration, 3), "text": text}) + "\n")
        print(f"{uid}  {duration:5.1f}s  {wav.name}  ->  {text[:60]}")
