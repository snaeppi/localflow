"""Prints the pinned file list (path, size, SHA-256) of a speech model for SpeechModels.Kind in
Sources/LocalflowApp/SpeechModel.swift.

usage: python3 scripts/speech-model-manifest.py REPO REVISION FOLDER
  REPO      e.g. FluidInference/parakeet-tdt-0.6b-v3-coreml
  REVISION  the commit to pin (huggingface.co/api/models/REPO/revision/main gives the latest)
  FOLDER    a local copy FluidAudio downloaded (~/Library/Application Support/FluidAudio/Models/…);
            it decides which files the model needs, the repository has more.

Large files' hashes come from Hugging Face's LFS metadata; small ones are downloaded and hashed.
"""
import hashlib
import json
import os
import sys
import urllib.parse
import urllib.request

repo, revision, folder = sys.argv[1], sys.argv[2], sys.argv[3]
tree = json.load(urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true"))
remote = {entry["path"]: entry for entry in tree if entry["type"] == "file"}
paths = sorted(os.path.relpath(os.path.join(root, name), folder) for root, _, names in os.walk(folder) for name in names)
total = 0
for path in paths:
    entry = remote[path]
    if "lfs" in entry:
        sha = entry["lfs"]["oid"]
    else:
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{urllib.parse.quote(path)}"
        sha = hashlib.sha256(urllib.request.urlopen(url).read()).hexdigest()
    total += entry["size"]
    print(f'            File("{path}", {entry["size"]}, "{sha}"),')
print(f"{len(paths)} files, {total} bytes", file=sys.stderr)
