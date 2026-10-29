"""Turns rewrite_cases.jsonl into realistic rewriter input: each case's `spoken` text is
synthesized with Kokoro (rotating US/UK voices) and transcribed by Parakeet Unified (FluidAudio's
pipeline) through localflow-bench, plain (`asr`) and with vocabulary boosting from the case's dictionary (`asr_vocab`).
Both get Transcriber.finalize's closing-period rule, as in the app.

usage: rewrite_asr.py <rewrite_cases.jsonl> <work-dir>    # writes <work-dir>/cases.jsonl
Run with the TTS venv (mlx-audio, misaki[en], soxr, soundfile); see bench/README.md.
"""

import json
import os
import subprocess
import sys

import numpy as np
import soundfile as sf
import soxr

VOICES = ["af_heart", "am_michael", "bf_emma", "bm_george", "af_bella", "am_fenrir"]
BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.build/release/localflow-bench")


def finalize(text):
    """Mirror of Transcriber.finalize."""
    text = text.strip()
    if text and (text[-1].isalnum() or text[-1] in "%)\"'") and len(text.split(" ")) >= 3:
        return text + "."
    return text


def main():
    cases_path, work = sys.argv[1], sys.argv[2]
    audio_dir = os.path.join(work, "audio")
    os.makedirs(audio_dir, exist_ok=True)
    cases = [json.loads(line) for line in open(cases_path) if line.strip()]

    from mlx_audio.tts.utils import load_model

    model = load_model("mlx-community/Kokoro-82M-bf16")
    manifest = os.path.join(work, "manifest.jsonl")
    with open(manifest, "w") as m:
        for i, case in enumerate(cases):
            voice = VOICES[i % len(VOICES)]
            path = os.path.join(audio_dir, case["id"] + ".wav")
            if not os.path.exists(path):
                chunks = [np.array(r.audio) for r in model.generate(text=case["spoken"], voice=voice, lang_code=voice[0])]
                sf.write(path, soxr.resample(np.concatenate(chunks), 24000, 16000), 16000, subtype="PCM_16")
            duration = sf.info(path).duration
            m.write(json.dumps({"id": case["id"], "subset": case["category"], "audio": "audio/" + case["id"] + ".wav",
                                "duration": duration, "dictionary": case.get("dictionary")}) + "\n")
            case["voice"] = voice

    results = {}
    for engine, field in (("parakeet-unified", "asr"), ("parakeet-unified-vocab", "asr_vocab")):
        prefix = os.path.join(work, engine)
        subprocess.run([BENCH, engine, manifest, prefix], check=True, stderr=subprocess.DEVNULL)
        for line in open(prefix + ".jsonl"):
            r = json.loads(line)
            results.setdefault(r["id"], {})[field] = (finalize(r["hyp"]), r["ms"])

    with open(os.path.join(work, "cases.jsonl"), "w") as out:
        for case in cases:
            for field, (text, ms) in results[case["id"]].items():
                case[field] = text
                case[field + "_ms"] = round(ms, 1)
            out.write(json.dumps(case) + "\n")


if __name__ == "__main__":
    main()
