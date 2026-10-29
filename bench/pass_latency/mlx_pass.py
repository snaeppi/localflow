"""lf_pass's measurement on MLX (mlx-lm, GPU): N tokens after POS cached, the next token after every one of
them (argmax on the GPU, timed through mx.eval). Median and best of REPS passes per N, after 5 unmeasured ones.

usage: mlx_pass.py MODEL_DIR [POS] [REPS]   (MODEL_DIR: an mlx_lm.convert output, see bench/README.md)
"""

import sys
import time

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    pos = int(sys.argv[2]) if len(sys.argv) > 2 else 130
    reps = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    model, _ = load(sys.argv[1])
    cache = make_prompt_cache(model)
    tokens = mx.array([1000 + (i * 7919) % 50000 for i in range(512)])  # as lf_pass
    mx.eval(model(tokens[None, :pos], cache=cache))
    for n in (1, 5, 11, 21, 32, 53, 128):
        batch = tokens[None, :n]
        mx.eval(batch)
        times = []
        for r in range(-5, reps):
            start = time.perf_counter()
            mx.eval(mx.argmax(model(batch, cache=cache), axis=-1))
            elapsed = (time.perf_counter() - start) * 1000
            trim_prompt_cache(cache, n)
            if r >= 0:
                times.append(elapsed)
        times.sort()
        print(f"N={n:3d}  median {times[reps // 2]:7.2f}  best {times[0]:7.2f} ms")


if __name__ == "__main__":
    main()
