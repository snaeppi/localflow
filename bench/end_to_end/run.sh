#!/bin/bash
# Key release to paste through the installed app, dictated as a user does: LFDriver holds Right ⌘, plays
# a clip of the cleanup test set on the speakers (Localflow listens on the built-in microphone) and
# releases 0.3 s after it ends; Localflow pastes into TextTarget. Every 4th case (55 clips), cleanup on,
# then off, with the recording window on and Always show off. Localflow's timing log and both helpers'
# timestamps go to scratch/end-to-end/<date-time>/, which summarize.py reads.
#
# The clips play aloud and TextTarget stays in front for ~22 minutes: a dictation is cancelled and the
# run stops if another app comes to the front. The settings file, microphone choice and speaker volume
# are put back afterwards.
#
# usage: bench/end_to_end/build.sh && bench/end_to_end/run.sh   (LIMIT=N: N clips per pass)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=${BIN:-/tmp/localflow-e2e}
TESTSET=$ROOT/scratch/rewrite/testset
OUT=$ROOT/scratch/end-to-end/$(date +%Y%m%d-%H%M)${LIMIT:+-trial}
SETTINGS=$HOME/Localflow/settings.json
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$OUT"
exec > >(tee -a "$OUT/log.txt") 2>&1

ln -sfn "$TESTSET/audio" "$OUT/audio"
awk 'NR % 4 == 1' "$TESTSET/cases.jsonl" | python3 -I -c '
import json, sys
clips = {json.loads(line)["id"]: line for line in open(sys.argv[1])}
for line in sys.stdin:
    print(clips[json.loads(line)["id"]], end="")' "$TESTSET/manifest.jsonl" > "$OUT/manifest.jsonl"

cp -p "$SETTINGS" "$OUT/settings.backup.json"
VOLUME=$(osascript -e 'output volume of (get volume settings)')
MUTED=$(osascript -e 'output muted of (get volume settings)')
MIC=$(defaults read io.github.snaeppi.localflow microphoneUID 2>/dev/null || true)

quit_localflow() { pkill -x Localflow; while pgrep -x Localflow >/dev/null; do sleep 0.2; done; }
restore() {
  quit_localflow
  pkill -x TextTarget
  cp -p "$OUT/settings.backup.json" "$SETTINGS"
  if [ -n "$MIC" ]; then defaults write io.github.snaeppi.localflow microphoneUID "$MIC"
  else defaults delete io.github.snaeppi.localflow microphoneUID 2>/dev/null; fi
  osascript -e "set volume output volume $VOLUME"
  [ "$MUTED" = true ] && osascript -e 'set volume with output muted'
  kill "$LOGPID" 2>/dev/null
  "$LSREGISTER" -u "$BIN/LFDriver.app"  # It has Localflow's bundle ID.
  open -a /Applications/Localflow.app
}
trap restore EXIT

/usr/bin/log stream --level info --style ndjson --predicate 'subsystem == "io.github.snaeppi.localflow"' \
  > "$OUT/localflow.ndjson" &
LOGPID=$!
osascript -e 'set volume without output muted' -e 'set volume output volume 40'

for pass in on off; do
  echo "== $(date +%T) cleanup $pass"
  quit_localflow
  python3 -I -c '
import json, sys
settings = json.load(open(sys.argv[1]))
settings.update(cleanup=sys.argv[2] == "on", showRecordingWindow=True, alwaysShowRecordingWindow=False)
json.dump(settings, open(sys.argv[3], "w"), indent=2)' "$OUT/settings.backup.json" $pass "$SETTINGS"
  defaults write io.github.snaeppi.localflow microphoneUID BuiltInMicrophoneDevice
  open -a /Applications/Localflow.app
  sleep 3
  open -n "$BIN/TextTarget.app" --args -log "$OUT/target-$pass.jsonl" -stay 1500
  sleep 2
  open -n -g -W --stdout "$OUT/driver-$pass.txt" --stderr "$OUT/driver-$pass.txt" "$BIN/LFDriver.app" \
    --args -manifest "$OUT/manifest.jsonl" -out "$OUT/driver-$pass.jsonl" ${LIMIT:+-limit $LIMIT}
  tail -1 "$OUT/driver-$pass.txt"
  pkill -x TextTarget
  grep -q '^stopped\|^no permission' "$OUT/driver-$pass.txt" && exit 1
done
python3 -I "$ROOT/bench/end_to_end/summarize.py" "$OUT"
