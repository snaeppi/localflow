"""Runs one rewriting engine over the cases (rewrite_cases.jsonl with `asr` filled in by
rewrite_asr.py) and writes per-case outputs and latencies as JSONL for rewrite_score.py.

Engines are llama.cpp servers, so every GGUF model is timed through the same runtime:
  llama-server -m MODEL.gguf --port 8090 -c 4096 -np 1 --jinja [-ngl 0] [--spec-type ngram-simple]
or anything else with an OpenAI-style chat endpoint (mlx_lm.server). `--idle-ms` sleeps before each case,
as between dictations.
`--identity` needs no server and passes the transcript through (the no-rewrite baseline).

usage: rewrite_bench.py <cases.jsonl> <out.jsonl> --format NAME [--url URL] [--input asr|asr_vocab]
                        [--category a,b] [--limit N] [--identity] [--idle-ms MS]
"""

import argparse
import json
import sys
import time
import urllib.request

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from rewrite_prompts import FORMATS  # noqa: E402

TIMING_KEYS = ("prompt_n", "prompt_ms", "predicted_n", "predicted_ms", "draft_n", "draft_n_accepted")


def post(url, body):
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)


def run(url, fmt, terms, text, max_tokens):
    common = {"temperature": 0, "max_tokens": max_tokens, "n_predict": max_tokens, "cache_prompt": True}
    if fmt.raw:
        reply = post(url + "/completion", {**common, "prompt": fmt.prompt(terms, text), "stop": ["\n### "]})
        return reply["content"], reply.get("timings", {})
    reply = post(url + "/v1/chat/completions", {
        **common,
        "messages": fmt.messages(terms, text),
        # Thinking off for Qwen3/3.5 templates (and harmless elsewhere).
        "chat_template_kwargs": {"enable_thinking": False},
    })
    return reply["choices"][0]["message"].get("content") or "", reply.get("timings", {})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cases")
    p.add_argument("out")
    p.add_argument("--url", default="http://127.0.0.1:8090")
    p.add_argument("--format", default="v1")
    p.add_argument("--input", default="asr")
    p.add_argument("--category", default="")
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--identity", action="store_true")
    p.add_argument("--idle-ms", type=int, default=0, help="untimed sleep before each case")
    args = p.parse_args()

    cases = [json.loads(line) for line in open(args.cases) if line.strip()]
    if args.category:
        cases = [c for c in cases if c["category"] in args.category.split(",")]
    if args.limit:
        cases = cases[: args.limit]
    fmt = FORMATS[args.format]

    if not args.identity:  # Warm-up: weights resident, dictionary-free prefix cached.
        run(args.url, fmt, [], "Hello there.", 16)

    with open(args.out, "w") as out:
        for case in cases:
            source = case[args.input]
            timings = {}
            if args.identity:
                output, ms = source, 0.0
            else:
                terms = case.get("dictionary") or []
                max_tokens = 48 + 2 * len(source.split())  # ~1.3 tokens per word, with headroom
                time.sleep(args.idle_ms / 1000)
                t0 = time.perf_counter()
                output, timings = run(args.url, fmt, terms, source, max_tokens)
                ms = (time.perf_counter() - t0) * 1000
            record = {"id": case["id"], "output": output.strip(), "ms": ms}
            if timings:
                record["timings"] = {k: timings[k] for k in TIMING_KEYS if k in timings}
            out.write(json.dumps(record) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
