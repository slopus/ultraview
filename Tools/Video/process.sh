#!/usr/bin/env bash
# Trims a recording to its scenario (0.7 s before it starts to 0.6 s after its last sample) and runs
# the analyzer on it. Writes <work dir>/<name>.mp4 and .json (the trimmed clip, its log's recording
# start moved to match) and the analyzer's <name>.csv, -summary.json, -summary.md and PNG sheets.
# farjump.py, widetitle.py and firstmove.py take <work dir>/<name> afterwards.
#   Tools/Video/process.sh <recording.mp4> <log.json> <work dir>
# The analyzer is built on first use into .context/analyze-video (ANALYZE_VIDEO overrides).
set -euo pipefail
video=$1 log=$2 work=$3
here=$(cd "$(dirname "$0")" && pwd)
analyzer=${ANALYZE_VIDEO:-.context/analyze-video}
if [[ ! -x $analyzer ]]; then
    mkdir -p "$(dirname "$analyzer")"
    swiftc -O "$here/analyze-video.swift" -o "$analyzer"
fi
mkdir -p "$work"
name=$(basename "$video" .mp4)
read -r start end < <(python3 - "$log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
offset = d["startedAtWall"] - d["host"]["recordingStartedWall"]
duration = d["samples"][-1]["time"] - d["startedAt"] if d["samples"] else 6
print(max(0, offset - 0.7), offset + duration + 0.6)
PY
)
start=$(python3 "$here/trim.py" "$video" "$work/$name.mp4" "$start" "$end")
python3 - "$log" "$work/$name.json" "$start" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["host"]["recordingStartedWall"] += float(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PY
"$analyzer" "$work/$name.mp4" "$work/$name.json" "$work" 2>/dev/null | sed -n '3,6p'
