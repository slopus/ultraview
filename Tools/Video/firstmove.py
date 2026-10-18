"""Tap -> first visible change for each tap of a -listVideoViews jump clip, from the app's
own clock (CACurrentMediaTime in the JSON, no host mapping):
  commit   the first main-thread commit after the tap whose visible list views (group 0, on screen,
           not hidden, opacity > 0) differ from the last commit before it in index, minY or contents
  sample   the first display-link sample whose rows (index, minY) differ from the last sample before
           the tap, and the first whose offset differs
  settle   the first sample from which the rows no longer move (|dy| < 0.01 pt to the clip's end or
           the next tap)
    python3 firstmove.py <clip stem: <dir>/<name> with <name>.json>"""
import json, os, sys
stem = sys.argv[1].removesuffix(".json"); name = os.path.basename(stem)
d = json.load(open(f"{stem}.json")); t0 = d["startedAt"]
top, height = d["lists"][0]["frame"][1], d["lists"][0]["frame"][3]
taps = [(e["time"] - t0, e.get("title")) for e in d["events"] if e["name"] == "tap"]
def visible(v):
    return v[0] == 0 and v[4] > 0.01 and not v[5] and v[6] < top + height and v[6] + v[7] > top
def state(views):
    return sorted((int(v[3]), round(v[6], 2), v[9]) for v in views if visible(v))
commits = [(c["time"] - t0, state(c["views"])) for c in d["commits"]]
samples = [(s["time"] - t0, s["frame"] - t0, [(r[0], r[1]) for r in s["rows"][0]], s["offsets"][0]) for s in d["samples"]]
for k, (tt, title) in enumerate(taps):
    end = taps[k + 1][0] if k + 1 < len(taps) else 1e9
    before = [c for c in commits if c[0] <= tt]
    base = before[-1][1] if before else None
    first_c = next((c for c in commits if tt < c[0] < end and c[1] != base), None)
    n_c = sum(1 for c in commits if tt < c[0] < (first_c[0] if first_c else end))
    sb = [s for s in samples if s[0] <= tt]
    rows0, off0 = sb[-1][2], sb[-1][3]
    first_r = next((s for s in samples if tt < s[0] < end and s[2] != rows0), None)
    first_o = next((s for s in samples if tt < s[0] < end and s[3] != off0), None)
    after = [s for s in samples if tt < s[0] < end]
    settle = None
    for i in range(len(after)):
        if all(after[j][2] == after[i][2] for j in range(i, len(after))): settle = after[i]; break
    f = lambda s, i=0: "-" if s is None else f"+{(s[i] - tt) * 1000:.1f} ms"
    print(f"{name} {title}: first visible change in a commit {f(first_c)} ({n_c} commits before it without one); "
          f"display-link sample: rows {f(first_r)}, offset {f(first_o)} (frame target {f(first_r, 1)}); "
          f"rows settle {f(settle)}")
    if first_r:
        print(f"    rows before {rows0[:3]} -> first changed sample {first_r[2][:3]}")
