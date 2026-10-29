"""Offline ASR benchmark for MLX models (via mlx-audio). Python twin of Sources/LocalflowBench.

Writes the exact same artifacts as the Swift harness so bench/score.py grades both identically:
  <out-prefix>.jsonl         one {"id", "hyp", "ms"} line per clip, in manifest order
  <out-prefix>.summary.json  {"engine","clips","load_ms","first_ms","rtfx",
                              "footprint_before_mb","footprint_peak_mb","mlx_peak_mb"} (+ "model")

usage: python bench/mlx_bench.py <engine> <manifest.jsonl> <out-prefix> [--limit N] [--model PATH_OR_REPO]
                                 [--idle-ms MS]
  engines: cohere-mlx-4bit cohere-mlx-8bit qwen3-asr-8bit granite-speech parakeet-v3-mlx

Timing contract (matches the Swift harness):
  * load_ms   - mlx_audio.stt.utils.load() of an already-downloaded model (weights evaluated, tokenizer built).
  * first_ms  - one warm-up transcription of the first clip; excluded from per-clip stats.
  * ms        - only the transcription call; audio is already a float32 mx.array at 16 kHz. The call returns a
                Python str (so the graph is materialized) and mx.synchronize() runs inside the timed region.
  * idle_ms   - untimed sleep before each clip, as between dictations (localflow-bench's BENCH_IDLE_MS).
  * rtfx      - total audio seconds / total transcribe seconds over the loop.
  * footprint - process phys_footprint (task_info TASK_VM_INFO, the same number the Swift harness reads),
                sampled before load and after every clip. mlx_peak_mb is mx.get_peak_memory() over the whole run.

Decoding: English, greedy, punctuation + capitalization on, no timestamps.
"""
import argparse
import ctypes
import json
import os
import re
import sys
import time
import wave
from pathlib import Path

import numpy as np

# name -> (HF repo, family). Override the repo/dir with --model.
ENGINES = {
    # No official mlx-community 4-bit exists; mlx-community's own "8bit" repo is an mlx-speech/HF-layout bf16
    # checkpoint that mlx-audio cannot load. These two use the mlx-audio-native layout (mlx-audio quantize, affine, g64).
    "cohere-mlx-4bit": ("lyzgeorge/cohere-transcribe-03-2026-mlx-4bit", "cohere"),
    "cohere-mlx-8bit": ("littoralai/cohere-transcribe-mlx-8bit", "cohere"),
    "qwen3-asr-8bit": ("mlx-community/Qwen3-ASR-1.7B-8bit", "qwen3"),
    # mlx-community only has the NAR variant; this is the autoregressive IBM Granite Speech 4.1 2B (LM weights
    # 4-bit affine g64, speech encoder + projector BF16; 2.6 GB). The -8bit repo is 3.3 GB, pass it via --model.
    "granite-speech": ("divydeep/granite-speech-4.1-2b-mlx-4bit", "granite"),
    # mlx-audio's Parakeet TDT, bf16 as mlx-audio runs it by default, the whole clip in one pass.
    "parakeet-v3-mlx": ("mlx-community/parakeet-tdt-0.6b-v3", "parakeet"),
}

GRANITE_PROMPT = "transcribe the speech with proper punctuation and capitalization."
MAX_TOKENS = 512  # clips are <= 25 s (~150 tokens); this only bounds runaway repetition

# ---------------------------------------------------------------------------------------------------------
# memory


class _TaskVMInfo(ctypes.Structure):
    # struct task_vm_info (mach/task_info.h), packed to 4 bytes; fields up to phys_footprint.
    _pack_ = 4
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("region_count", ctypes.c_int32),
        ("page_size", ctypes.c_int32),
        ("resident_size", ctypes.c_uint64),
        ("resident_size_peak", ctypes.c_uint64),
        ("device", ctypes.c_uint64),
        ("device_peak", ctypes.c_uint64),
        ("internal", ctypes.c_uint64),
        ("internal_peak", ctypes.c_uint64),
        ("external", ctypes.c_uint64),
        ("external_peak", ctypes.c_uint64),
        ("reusable", ctypes.c_uint64),
        ("reusable_peak", ctypes.c_uint64),
        ("purgeable_volatile_pmap", ctypes.c_uint64),
        ("purgeable_volatile_resident", ctypes.c_uint64),
        ("purgeable_volatile_virtual", ctypes.c_uint64),
        ("compressed", ctypes.c_uint64),
        ("compressed_peak", ctypes.c_uint64),
        ("compressed_lifetime", ctypes.c_uint64),
        ("phys_footprint", ctypes.c_uint64),
        ("_rest", ctypes.c_uint8 * 256),  # remaining (newer) fields; size only needs to be >= the real struct
    ]


_libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_libsystem.mach_task_self.restype = ctypes.c_uint32
_TASK_VM_INFO = 22


def footprint_mb() -> float:
    """Process physical footprint in MB (same metric as the Swift harness); falls back to peak RSS."""
    try:
        info = _TaskVMInfo()
        count = ctypes.c_uint32(ctypes.sizeof(info) // 4)
        kr = _libsystem.task_info(_libsystem.mach_task_self(), _TASK_VM_INFO, ctypes.byref(info), ctypes.byref(count))
        if kr == 0 and info.phys_footprint:
            return info.phys_footprint / 1048576
    except Exception:
        pass
    import resource

    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576  # bytes on macOS


# ---------------------------------------------------------------------------------------------------------
# audio + text helpers


def read_samples(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


_SPECIAL = re.compile(r"<\|[^|>]*\|>|</?s>|<unk>|<pad>|\[PAD\]")


def clean(text: str) -> str:
    """Strip leaked special tokens / Qwen 'language X<asr_text>' prefix and normalize whitespace."""
    if "<asr_text>" in text:
        text = text.split("<asr_text>", 1)[1]
    text = _SPECIAL.sub(" ", text)
    return " ".join(text.split())


# ---------------------------------------------------------------------------------------------------------
# engines


def resolve_model_dir(model: str) -> str:
    """Local dir as-is; otherwise HF snapshot (cache first, download only if missing). Untimed."""
    if os.path.isdir(model):
        return model
    from huggingface_hub import snapshot_download

    try:
        return snapshot_download(model, local_files_only=True)
    except Exception:
        return snapshot_download(model)


def make_transcriber(family: str, model):
    import mlx.core as mx

    def finish(text: str) -> str:
        mx.synchronize()  # nothing may still be in flight when the timer stops
        return clean(text)

    if family == "cohere":
        return lambda a: finish(
            model.generate(a, language="en", punctuation=True, batch_size=1, max_tokens=MAX_TOKENS).text
        )
    if family == "qwen3":
        return lambda a: finish(model.generate(a, language="English", max_tokens=MAX_TOKENS).text)
    if family == "granite":
        return lambda a: finish(model.generate(a, prompt=GRANITE_PROMPT, max_tokens=MAX_TOKENS).text)
    if family == "parakeet":
        return lambda a: finish(model.generate(a).text)
    raise ValueError(family)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("engine", choices=sorted(ENGINES))
    ap.add_argument("manifest")
    ap.add_argument("out_prefix")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--model", default=None, help="override the HF repo id / local model directory")
    ap.add_argument("--idle-ms", type=int, default=0, help="untimed sleep before each clip")
    args = ap.parse_args()

    repo, family = ENGINES[args.engine]
    model_ref = args.model or repo

    manifest = Path(args.manifest).expanduser()
    base = manifest.parent
    clips = [json.loads(line) for line in manifest.read_text().splitlines() if line.strip()]
    if args.limit is not None:
        clips = clips[: args.limit]
    if not clips:
        sys.exit("no clips")

    out_prefix = os.path.expanduser(args.out_prefix)
    os.makedirs(os.path.dirname(os.path.abspath(out_prefix)), exist_ok=True)

    import mlx.core as mx
    from mlx_audio.stt.utils import load

    model_dir = resolve_model_dir(model_ref)  # fetch weights if missing (untimed)
    mem0 = footprint_mb()
    mx.reset_peak_memory()

    t = time.perf_counter()
    # Parakeet's config has no model_type; mlx-audio guesses it from a repo name, which a snapshot path lacks.
    hint = {"model_type": "parakeet"} if family == "parakeet" else {}
    model = load(model_dir, **hint)  # non-lazy: parameters are evaluated before this returns
    mx.synchronize()
    load_ms = (time.perf_counter() - t) * 1000

    transcribe = make_transcriber(family, model)

    # First inference pays any remaining kernel compile / allocator warm-up.
    warm = mx.array(read_samples(base / clips[0]["audio"]))
    mx.eval(warm)
    t = time.perf_counter()
    transcribe(warm)
    first_ms = (time.perf_counter() - t) * 1000

    peak = footprint_mb()
    total_audio = 0.0
    total_ms = 0.0
    with open(out_prefix + ".jsonl", "w") as out:
        for clip in clips:
            audio = mx.array(read_samples(base / clip["audio"]))
            mx.eval(audio)  # make sure the upload is not billed to the transcription
            if args.idle_ms:
                time.sleep(args.idle_ms / 1000)
            t = time.perf_counter()
            hyp = transcribe(audio)
            ms = (time.perf_counter() - t) * 1000
            total_audio += clip["duration"]
            total_ms += ms
            peak = max(peak, footprint_mb())
            out.write(json.dumps({"id": clip["id"], "hyp": hyp, "ms": ms}) + "\n")
            out.flush()

    summary = {
        "engine": args.engine,
        "clips": len(clips),
        "load_ms": load_ms,
        "first_ms": first_ms,
        "rtfx": total_audio / (total_ms / 1000),
        "footprint_before_mb": mem0,
        "footprint_peak_mb": peak,
        "mlx_peak_mb": mx.get_peak_memory() / 1048576,
        "model": model_ref,
        "idle_ms": args.idle_ms,
    }
    with open(out_prefix + ".summary.json", "w") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
