"""Old row titles after Top in a far-jump clip, from pixels: after Top every legit
row title is 'Row <one digit>' (it ends before x = 90 pt), while an old one from the 5,000 window
('Row 4,99x', 'Row 5,00x') runs past x = 100 pt. A title line is a run of rows with black
(grey < 60) pixels whose leftmost black pixel is at x 38-50 pt (right of the row's dot; section
headers are centred and cards are white on colour). Reports every frame from the Top tap on with
such a line reaching x >= 100 pt, with its y (pt) and extent; partly covered titles count too.
    python3 widetitle.py <clip stem>   (process.sh output: <stem>.mp4, .json and .csv)"""
import csv, json, os, subprocess, sys
stem = sys.argv[1].removesuffix(".json"); name = os.path.basename(stem)
W, H, S = 586, 1268, 1.5
TOP, BOTTOM = 232, 761
d = json.load(open(f"{stem}.json")); t0 = d["startedAt"]
taps = [(e["time"] - t0, e.get("title")) for e in d["events"] if e["name"] == "tap"]
top_t = next(t for t, title in taps if title == "Top")
rows = list(csv.DictReader(open(f"{stem}.csv")))
app = [float(r["app_time"]) for r in rows]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{stem}.mp4", "-fps_mode", "passthrough",
                      "-vf", "format=gray", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
F = [raw[k * W * H:(k + 1) * W * H] for k in range(len(raw) // (W * H))]
start = max(i for i, a in enumerate(app) if a <= top_t)
hits = []
for i in range(start, len(F)):
    f = F[i]; found = []; run = None
    for y in range(int(TOP * S), int(BOTTOM * S)):
        xs = [x for x in range(int(30 * S), int(260 * S)) if f[y * W + x] < 60]
        line = bool(xs) and int(38 * S) <= xs[0] <= int(50 * S)
        if line:
            if run is None: run = [y, y, xs[0], xs[-1]]
            else: run[1] = y; run[2] = min(run[2], xs[0]); run[3] = max(run[3], xs[-1])
        elif run is not None:
            if run[1] - run[0] >= 2: found.append(run)
            run = None
    if run is not None and run[1] - run[0] >= 2: found.append(run)
    wide = [(round(a / S), round(b / S), round(l / S), round(r / S)) for a, b, l, r in found if r >= int(100 * S)]
    if wide:
        hits.append(i)
        print(f"#{i:<4} +{(app[i] - top_t) * 1000:7.1f} ms  wide title line(s): " +
              "; ".join(f"y {a}-{b} pt, x {l}-{r}" for a, b, l, r in wide))
if hits:
    print(f"{name}: frames with an old title after Top: {len(hits)}, #{hits[0]}..#{hits[-1]} "
          f"(+{(app[hits[0]] - top_t) * 1000:.0f} .. +{(app[hits[-1]] - top_t) * 1000:.0f} ms)")
else:
    print(f"{name}: no old title after Top (frames #{start}..#{len(F) - 1})")
