"""From a -listVideoViews clip's commit log: for every visible row view
(group 0) whose index or height changes in a commit, or that first becomes
visible, are its final contents in that same commit, or do they land later?
    python3 commitlag.py <clip stem: <dir>/<name> with <name>.json> [--all]
A change passes when no contents change follows it (within 1 s, while index and
height stay put): frame and contents landed in one commit. A later change is
reported with its delay and the tallest bitmap before and after it (old vs new
text), and whether a 60 Hz display frame could have shown the stale state."""
import json, os, sys
stem = sys.argv[1].removesuffix(".json"); name = os.path.basename(stem); verbose = "--all" in sys.argv
d = json.load(open(f"{stem}.json")); t0 = d["startedAt"]
top, height = d["lists"][0]["frame"][1], d["lists"][0]["frame"][3]
taps = [(e["time"] - t0, e.get("title")) for e in d["events"] if e["name"] == "tap"]
def tap_at(t):
    xs = [(tt, title) for tt, title in taps if tt <= t + 0.002]
    return xs[-1] if xs else (0, "lead-in")
def visible(v):
    return v[0] == 0 and v[4] > 0.01 and not v[5] and v[6] < top + height and v[6] + v[7] > top
commits = [(c["time"] - t0, [v for v in c["views"] if visible(v)]) for c in d["commits"]]
changes = []  # [kind, tap, time, addr, index, height, layers, tallest, sig, last change time, final tallest]
last = {}
for t, views in commits:
    for v in views:
        addr, idx, h, count, sig, tallest = v[2], int(v[3]), round(v[7], 1), int(v[8]), v[9], v[10]
        prev = last.get(addr)
        if prev is None or (idx, h) != prev[:2]:
            kind = "shown" if prev is None else ("reindexed" if idx != prev[0] else "resized")
            changes.append([kind, tap_at(t), t, addr, idx, h, count, tallest, sig, None, tallest])
        else:
            for c in reversed(changes):
                if c[3] == addr:
                    if t - c[2] <= 1.0 and sig != c[8] and (c[9] is None or sig != prev[2]):
                        c[9], c[10] = t, tallest
                    break
        last[addr] = (idx, h, sig)
    for addr in [a for a in last if a not in {v[2] for v in views}]: last.pop(addr)
by_tap = {}
for c in changes:
    if c[1][1] == "lead-in" and c[0] == "shown": continue
    by_tap.setdefault((round(c[1][0], 3), c[1][1]), []).append(c)
total = {"changes": 0, "late": 0, "blank": 0}
for (tt, title), xs in sorted(by_tap.items()):
    late = [c for c in xs if c[9] is not None]
    blank = [c for c in xs if c[6] == 0]
    total["changes"] += len(xs); total["late"] += len(late); total["blank"] += len(blank)
    print(f"{name}  {title} @{tt:.3f}s: {len(xs)} frame changes, {len(late)} with contents in a later commit ({len(blank)} shown with no contents)")
    for kind, tp, t1, addr, i, h, count, tallest, sig, t2, final in xs:
        if t2 is None and not verbose: continue
        if t2 is None: what = "same commit"
        else:
            lag = (t2 - t1) * 1000
            what = f"contents +{lag:.1f} ms later (tallest bitmap {tallest:g} -> {final:g} pt){'  >= 1 frame' if lag >= 16.6 else ''}"
        print(f"    {kind:<9} row {i:<5} h {h:6.1f} layers {count}  at {t1:.3f}s  {what}")
print(f"SUMMARY {name}: {total['changes']} frame changes, {total['late']} late contents, {total['blank']} blank")
