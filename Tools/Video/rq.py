"""Readiness frame QA for one raw recording (simulator or XCTest; feed or chat, touch test or clip) and its
JSON, from the pixels only. Frames are decoded at 1 px per pt (390 x 844, area filter, yuv444p).
Per frame, inside the list frame from the JSON (x 4-381, so the scroll indicator is masked):
  bg     longest run of lines that are background only (every Y within 7 of the frame's background
         level, read at x 1-3 on the list's middle line, and no tinted pixel): where a row or a
         carousel should be and nothing is drawn; > 48 pt is flagged (the widest natural one is 44,
         under a carousel). Runs that touch the list's top or bottom edge are
         marked (overscroll or the end of the content, not a missing row).
  white  longest run of lines that are card white (Y >= 248 over x 24-366): a row card with its
         background but none of its text.
  cards  (feed only) carousel bands: runs of >= 20 lines with >= 25 % tinted pixels (|U-128| or |V-128| > 20).
         In each band, columns are card columns when >= 50 % of the band's lines are tinted there; the
         widest stretch of non-card columns between x 0 and 390 is the band's hole (gaps between
         cards are 8 pt, the carousel's leading inset 6 pt). A hole > 24 pt is a card not drawn.
  edge   for the first band, the x of the card left edges; the per-frame shift of the cards is the
         median change of the nearest edges (|change| < 70 pt).
  moved  lines of the list frame whose bytes changed from the previous frame.
Stalls, from the frame intervals (a recording writes one frame per screen change): an interval
over 1.5 display frames (25 ms at 60 Hz) between two moving frames, each with an interval under 25
ms on its other side (continuous motion around the hole), is a stall of round(interval / 16.7 ms)
- 1 skipped frames; 6 or more skipped is a pause (a finger hold looks like this), listed
separately. A 60 Hz grid fitted to the whole recording drifts by several ms over seconds, so it
only labels frames (--frames). Moving: >= 20 changed list lines, or with --carousel the cards
shifting >= 2 pt.
    python3 rq.py <mp4> <json> [--from s] [--to s] [--carousel] [--frames]      (app time; default the scenario window)
Prints a summary line and the flagged frames; writes <out>/<clip>.rq.json when RQ_OUT is set."""
import json, math, os, statistics, subprocess, sys
video, meta = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
def opt(name, default=None):
    return float(args[args.index(name) + 1]) if name in args else default
W, H = 390, 844
P = 1 / 60
d = json.load(open(meta))
lf = d["lists"][0]["frame"]
FEED = d.get("listScreen") == "feed"  # carousels only in the feed; tinted bands elsewhere are swipe actions
TOP, BOTTOM = int(math.ceil(lf[1])), int(math.floor(lf[1] + lf[3]))
offset = d["startedAtWall"] - d["host"]["recordingStartedWall"]  # video pts of app time startedAt
t0 = d["startedAt"]
events = [(e["time"] - t0 + offset, e.get("title") or e["name"]) for e in d.get("events", [])]
pts = [float(t.strip(",")) for t in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                                    "-of", "csv=p=0", video], capture_output=True, text=True, check=True).stdout.split()]
proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"scale={W}:{H}:flags=area,format=yuv444p",
                         "-f", "rawvideo", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
N = W * H
TINT = bytes(1 if abs(v - 128) > 20 else 0 for v in range(256))
X0, X1 = 4, 382
def band_columns(Ulines, Vlines):
    acc = 0
    for u, v in zip(Ulines, Vlines):
        acc += int.from_bytes(u.translate(TINT), "big") | int.from_bytes(v.translate(TINT), "big")
    return acc.to_bytes(W, "big")
rows = []
prevY = None
i = 0
while True:
    buf = proc.stdout.read(3 * N)
    if len(buf) < 3 * N: break
    Y, U, V = buf[:N], buf[N:2 * N], buf[2 * N:]
    ylines = [Y[y * W:(y + 1) * W] for y in range(H)]
    mid = (TOP + BOTTOM) // 2
    bgl = statistics.median(ylines[mid][1:4])
    tinted = []
    for y in range(H):
        u, v = U[y * W:(y + 1) * W], V[y * W:(y + 1) * W]
        tinted.append((int.from_bytes(u.translate(TINT), "big") | int.from_bytes(v.translate(TINT), "big")).bit_count())
    # bg / white runs inside the list frame
    best_bg, bg_at, run, start = 0, None, 0, None
    best_w, w_at, wrun, wstart = 0, None, 0, None
    for y in range(TOP, BOTTOM):
        seg = ylines[y][X0:X1]
        isbg = tinted[y] == 0 and max(seg) <= bgl + 7 and min(seg) >= bgl - 7
        if isbg:
            if run == 0: start = y
            run += 1
            if run > best_bg: best_bg, bg_at = run, (start, y + 1)
        else: run = 0
        iswhite = min(ylines[y][24:366]) >= 248
        if iswhite:
            if wrun == 0: wstart = y
            wrun += 1
            if wrun > best_w: best_w, w_at = wrun, (wstart, y + 1)
        else: wrun = 0
    # carousel bands
    bands, y = [], TOP
    while y < BOTTOM:
        if tinted[y] >= 0.25 * W:
            s = y
            while y < BOTTOM and tinted[y] >= 0.25 * W: y += 1
            if y - s >= 20: bands.append((s, y))
        else: y += 1
    holes, edges = [], []
    for k, (s, e) in enumerate(bands if FEED else []):
        lines = range(s, e, 1 + (e - s) // 250)  # byte lanes hold counts up to 255
        cols = band_columns([U[yy * W:(yy + 1) * W] for yy in lines], [V[yy * W:(yy + 1) * W] for yy in lines])
        card = [c >= 0.5 * len(lines) for c in cols]
        hole, hx, x = 0, None, 0
        while x < W:
            if not card[x]:
                xs = x
                while x < W and not card[x]: x += 1
                if x - xs > hole: hole, hx = x - xs, (xs, x)
            else: x += 1
        holes.append((hole, hx))
        if k == 0: edges = [x for x in range(1, W) if card[x] and not card[x - 1]]
    moved = 0
    if prevY is not None:
        moved = sum(1 for y in range(TOP, BOTTOM) if Y[y * W + X0:y * W + X1] != prevY[y * W + X0:y * W + X1])
    prevY = Y
    rows.append({"i": i, "pts": pts[i] if i < len(pts) else None, "bg": best_bg, "bgAt": bg_at, "white": best_w, "whiteAt": w_at,
                 "bands": bands, "holes": holes, "edges": edges, "moved": moved})
    i += 1
proc.wait()
# card shift per frame
for a, b in zip(rows, rows[1:]):
    sh = []
    for x in b["edges"]:
        if a["edges"]:
            n = min(a["edges"], key=lambda e: abs(e - x))
            if abs(n - x) < 70: sh.append(x - n)
    b["shift"] = statistics.median(sh) if sh else None
rows[0]["shift"] = None
# 60 Hz grid
ang = [2 * math.pi * ((r["pts"] % P) / P) for r in rows]
phase = (math.atan2(sum(map(math.sin, ang)), sum(map(math.cos, ang))) / (2 * math.pi)) % 1 * P
for r in rows:
    r["tick"] = math.floor((r["pts"] - phase + 0.003) / P)
    r["app"] = r["pts"] - offset
# Default window: the scenario, from its start to its last sample (app time, s).
lo, hi = opt("--from", 0.0), opt("--to", (d["samples"][-1]["time"] - t0) if d.get("samples") else 1e9)
sel = [r for r in rows if lo <= r["app"] <= hi]
# The widest natural background stretch is 44 pt (under a carousel: its inset plus the row gap).
BGMAX = 48
# Moving: with --carousel the cards shifted >= 2 pt; otherwise >= 20 list lines changed.
carousel = "--carousel" in args
def moving(r):
    return (r.get("shift") is not None and abs(r["shift"]) >= 2) if carousel else r["moved"] >= 20
stalls, pauses = [], []
LONG = 1.5 * P
for j in range(2, len(sel) - 1):
    a, b = sel[j - 1], sel[j]
    dt = b["pts"] - a["pts"]
    skipped = round(dt / P) - 1
    # continuous on both sides: no long interval just before a or just after b
    if dt > LONG and moving(a) and moving(b) and a["pts"] - sel[j - 2]["pts"] < LONG and sel[j + 1]["pts"] - b["pts"] < LONG:
        entry = {"frame": b["i"], "app": round(b["app"], 3), "skipped": skipped, "dtMs": round(dt * 1000, 1),
                 "shiftBefore": a.get("shift"), "shiftAcross": b.get("shift"), "shiftAfter": sel[j + 1].get("shift"),
                 "movedBefore": a["moved"], "movedAcross": b["moved"], "movedAfter": sel[j + 1]["moved"]}
        (stalls if skipped <= 5 else pauses).append(entry)
flag = [r for r in sel if (r["bg"] > BGMAX and r["bgAt"] and r["bgAt"][0] > TOP + 1 and r["bgAt"][1] < BOTTOM - 1) or r["white"] > 40
        or any(h > 24 for h, _ in r["holes"])]
edge_bg = [r for r in sel if r["bg"] > BGMAX and r not in flag]
name = os.path.basename(video)[:-4]
print(f"{name}: {len(sel)} frames, list y {TOP}-{BOTTOM}, max bg {max((r['bg'] for r in sel), default=0)} pt "
      f"(interior >{BGMAX}: {sum(1 for r in flag if r['bg'] > BGMAX)}, at an edge: {len(edge_bg)}), max white {max((r['white'] for r in sel), default=0)} pt, "
      f"carousel frames {sum(1 for r in sel if r['bands'])}, max hole {max((h for r in sel for h, _ in r['holes']), default=0)} pt, "
      f"flagged {len(flag)}, stalls {len(stalls)} ({sum(s['skipped'] for s in stalls)} ticks), pauses {len(pauses)}")
for r in flag:
    print(f"  #{r['i']} app {r['app']:.3f} bg {r['bg']} {r['bgAt']} white {r['white']} {r['whiteAt']} bands {r['bands']} holes {r['holes']}")
for s in stalls:
    print("  stall", s)
for s in pauses:
    print("  pause", s)
if "--frames" in args:
    for r in sel:
        print(f"  #{r['i']} {r['pts']:.4f} app {r['app']:.3f} t{r['tick']} moved {r['moved']} shift {r['shift']} bg {r['bg']} {r['bgAt']} white {r['white']} bands {r['bands']} holes {r['holes']}")
if os.environ.get("RQ_OUT"):
    json.dump({"name": name, "offset": offset, "events": events, "list": [TOP, BOTTOM], "phase": phase, "stalls": stalls, "pauses": pauses,
               "mainThread": d.get("mainThread"), "test": d["host"].get("test"), "testStatus": d["host"].get("testStatus"),
               "frames": [{k: r[k] for k in ("i", "pts", "app", "tick", "moved", "shift", "bg", "bgAt", "white", "whiteAt", "bands", "holes")} for r in rows]},
              open(f"{os.environ['RQ_OUT']}/{name}.rq.json", "w"))
