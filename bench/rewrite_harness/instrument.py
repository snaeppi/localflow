# Writes a copy of the app's Rewriter.swift with pass counters (Stats in main.swift). Fails loudly
# if Rewriter.swift changed shape: update the anchors below together with the decoding loop.
# usage: python3 instrument.py SOURCES/LocalflowApp/Rewriter.swift OUT/Rewriter.swift
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()


def rep(old, new):
    global s
    if s.count(old) != 1:
        sys.exit(f"instrument.py: anchor not found exactly once in {src}:\n{old}")
    s = s.replace(old, new)


rep("        var output: [Int32] = []\n        while true {\n"
    "            try decode(pending + draft, at: position, outputs: 1 + draft.count)\n",
    "        var output: [Int32] = []\n        var first = true\n        while true {\n"
    "            let started = ContinuousClock.now\n"
    "            try decode(pending + draft, at: position, outputs: 1 + draft.count)\n"
    "            let us = (ContinuousClock.now - started).microseconds\n")
rep("            drafter.advance(by: accepted)\n",
    "            if Stats.enabled {\n"
    "                if first {\n"
    "                    Stats.first.append((pending.count + draft.count, draft.count, accepted, us))\n"
    "                } else {\n"
    "                    Stats.verify.append((draft.count, accepted, us))\n"
    "                }\n"
    "            }\n"
    "            first = false\n"
    "            drafter.advance(by: accepted)\n")
open(dst, "w").write(s)
