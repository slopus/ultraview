"""Stale pixels during a far jump's travel (feed screen, -listScenario jump), from the
recording only.

A far jump shows two rigid blocks inside the list (y 232-761 pt): the old rows (the frame before
the tap, shifted by s_old) and the destination rows (the rest frame after the travel, shifted by
s_new), meeting at a seam. For every frame from the tap to the rest frame:
  shifts   per reference, tracked frame to frame (old block forward from the tap, destination
           backward from rest) within 60 pt of the previous shift plus its last step: the integer
           shift that matches the most 4 pt line samples (mean |diff| < 4 over 30 columns), refined
           to 1/6 pt by SAD over those lines; under 8 matching samples, or no run of
           them 30 pt long, the block is off screen.
           The old reference only explains blocks inside its own longest matched run of lines.
  blocks   6 x 6 pt; residual = |mean difference| over the block (glyph edges rasterized at
           another subpixel phase cancel in the mean: <= 1.5 on text), the smallest over
           either reference at its shift +- 0.5 pt (1/6 steps, linear interpolation), using only
           references whose shifted rows cover the block; residual > 6 grey levels = stale (a
           white card over the 242 background is 12-13, old text 20-130). The scroll indicator
           column (x >= 383) is masked; blocks neither reference covers (the destination's rows
           below its rest view, mid-flight) are 'uncovered' and not counted: widetitle.py
           covers old titles there.
  kinds    by where the block sits in the rest layout (y - s_new): 'gap' inside the carousel row
           and not on a card, 'margin' x < 12 or x > 378 elsewhere, 'row' anywhere else; blocks on
           a section header's label (x 126-264 next to centred black text) are 'header' and not
           stale rows (the pinned header's label changes with its section)
    python3 farjump.py <clip stem> [--frames]   (process.sh output: <stem>.mp4, .json and .csv)
Frames are decoded at 1 px per pt (area filter). Writes <stem>.farjump.json."""
import csv, json, os, subprocess, sys
stem = sys.argv[1].removesuffix(".json"); name = os.path.basename(stem)
W, H = 390, 844
TOP, BOTTOM = 232, 761
d = json.load(open(f"{stem}.json")); t0 = d["startedAt"]
taps = [(e["time"] - t0, e.get("title")) for e in d["events"] if e["name"] == "tap"]
rows = list(csv.DictReader(open(f"{stem}.csv")))
app = [float(r["app_time"]) for r in rows]
def decode(fmt, n):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{stem}.mp4", "-fps_mode", "passthrough",
                          "-vf", f"scale={W}:{H}:flags=area,format={fmt}", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    return [raw[k * W * H * n:(k + 1) * W * H * n] for k in range(len(raw) // (W * H * n))]
F = decode("gray", 1)
assert len(F) == len(rows), (len(F), len(rows))
COLS = list(range(14, 376, 12))

def line_diff(f, y, ref, yr):
    return sum(abs(f[y * W + x] - ref[yr * W + x]) for x in COLS) / len(COLS)

SEGS = [range(14, 134, 6), range(134, 254, 6), range(254, 376, 6)]
def profile(f):
    return [tuple(sum(f[y * W + x] for x in seg) / len(seg) for seg in SEGS) for y in range(H)]

def best_shift(f, ref, lo, hi, pf, pr, lines_only=False):
    """Integer shift with the most matching 4 pt line samples (candidates from the per-line
    three-segment mean profile), and those lines."""
    lines2 = list(range(TOP, BOTTOM, 2))
    scores = []
    for s in range(lo, hi + 1):
        c = 0
        for y in lines2:
            yr = y - s
            if TOP <= yr < BOTTOM:
                a, b = pf[y], pr[yr]
                if abs(a[0] - b[0]) < 3 and abs(a[1] - b[1]) < 3 and abs(a[2] - b[2]) < 3: c += 1
        scores.append((c, s))
    scores.sort(reverse=True)
    best = (0, None, [])
    lines = list(range(TOP, BOTTOM, 4))
    for _, s in scores[:6]:
        m = [y for y in lines if TOP <= y - s < BOTTOM and line_diff(f, y, ref, y - s) < 4]
        if len(m) > best[0]: best = (len(m), s, m)
    return best

def interp(ref, yf, x):
    y0 = int(yf // 1); a = yf - y0
    if y0 < TOP or y0 + 1 >= BOTTOM: return None
    return ref[y0 * W + x] * (1 - a) + ref[(y0 + 1) * W + x] * a

def refine(f, ref, s, lines):
    def cost(sf):
        tot = n = 0
        for y in lines:
            for yy in (y, y + 1, y + 2):
                for x in COLS:
                    v = interp(ref, yy - sf, x)
                    if v is not None: tot += abs(f[yy * W + x] - v); n += 1
        return tot / max(1, n)
    return min((s + k / 6 for k in range(-6, 7)), key=cost)

def block_res(f, ref, s, bx, by):
    """|mean difference| over the block (glyph edges rasterized at another subpixel phase
    cancel in the mean, stale paint doesn't), minimized over s +- 0.5 pt."""
    best = None
    for k in (0, -1, 1, -2, 2, -3, 3):
        sf = s + k / 6; a = b = 0
        for y in range(by, by + 6):
            for x in range(bx, bx + 6):
                v = interp(ref, y - sf, x)
                if v is None: return None
                a += f[y * W + x]; b += v
        r = abs(a - b) / 36
        if best is None or r < best: best = r
        if best <= 6: return best
    return best

out = {}
RGB = None
for k, (tt, title) in enumerate(taps):
    end_t = taps[k + 1][0] if k + 1 < len(taps) else app[-1] + 1
    i0 = max(i for i, a in enumerate(app) if a <= tt)        # the frame before the tap
    i1 = max(i for i, a in enumerate(app) if a < end_t)       # rest: the last frame before the next tap
    pre, rest = F[i0], F[i1]
    ppre, prest = profile(pre), profile(rest)
    if RGB is None: RGB = decode("rgb24", 3)
    rgb = RGB[i1]
    def card(y, x):
        p = rgb[(y * W + x) * 3:(y * W + x) * 3 + 3]
        return max(p) - min(p) > 60
    card_lines = [y for y in range(TOP, BOTTOM) if sum(card(y, x) for x in range(0, W, 6)) > 20]
    band = (min(card_lines), max(card_lines)) if card_lines else None
    report = []
    # Track each block through the travel: the old one forward from the tap, the destination
    # backward from rest, each frame searched within 60 pt of the previous shift plus its last step
    # (rows repeat, so an unconstrained search can lock a row height off). A block with fewer than
    # 8 matching line samples is gone (old) or not yet on screen (destination).
    prof = {i: profile(F[i]) for i in range(i0, i1 + 1)}
    def track(order, ref, pref):
        out, prev, step = {}, 0.0, 0.0
        for i in order:
            guess = round(prev + step)
            n, s0, m = best_shift(F[i], ref, guess - 60, guess + 60, prof[i], pref)
            if n < 8: break
            sf = refine(F[i], ref, s0, m)
            # the old block's own lines: the longest run of matched samples (gaps <= 12 pt)
            runs, cur = [], [m[0], m[0]]
            for y in m[1:]:
                if y - cur[1] <= 12: cur[1] = y
                else: runs.append(cur); cur = [y, y]
            runs.append(cur)
            span = max(runs, key=lambda r: r[1] - r[0])
            if span[1] - span[0] < 30: break
            out[i] = (sf, n, (span[0], span[1] + 4))
            step, prev = sf - prev, sf
        return out
    olds = track(range(i0, i1 + 1), pre, ppre)
    news = track(range(i1, i0 - 1, -1), rest, prest)
    for i in range(i0, i1 + 1):
        f = F[i]
        s_new, nn, _ = news.get(i, (None, 0, None))
        s_old, no, old_span = olds.get(i, (None, 0, None))
        # section header labels (centred bold text, pinned or not) change with the section they
        # belong to; blocks on them are tagged 'header', not counted as stale rows
        heads = [y for y in range(TOP, BOTTOM) if any(f[y * W + x] < 60 for x in range(140, 250))
                 and not any(f[y * W + x] < 60 for x in list(range(20, 136)) + list(range(256, 383)))]
        stale = {"margin": 0, "gap": 0, "row": 0, "header": 0}; boxes = []; uncovered = 0
        for by in range(TOP, BOTTOM - 6, 6):
            for bx in range(0, 383 - 6, 6):
                use_old = s_old is not None and old_span[0] - 6 <= by and by + 6 <= old_span[1] + 6
                rs = [r for r in (block_res(f, rest, s_new, bx, by) if s_new is not None else None,
                                  block_res(f, pre, s_old, bx, by) if use_old else None) if r is not None]
                if not rs: uncovered += 1; continue
                r = min(rs)
                if r <= 6: continue
                if bx >= 126 and bx + 6 <= 264 and any(by - 8 <= y <= by + 14 for y in heads):
                    stale["header"] += 1; continue
                yr = int(by + 3 - (s_new or 0))
                in_band = band is not None and TOP <= yr < BOTTOM and band[0] - 6 <= yr <= band[1] + 6
                if in_band and not card(min(max(yr, TOP), BOTTOM - 1), bx + 3): kind = "gap"
                elif bx < 12 or bx + 6 > 378: kind = "margin"
                else: kind = "row"
                stale[kind] += 1; boxes.append((bx, by, round(r, 1), kind))
        report.append(dict(frame=i, app=app[i], t=app[i] - tt, s_new=s_new, s_old=s_old, lines_new=nn, lines_old=no,
                           old_span=old_span, uncovered=uncovered, stale=stale, boxes=boxes))
    out[title] = dict(tap=tt, first_frame=i0, rest_frame=i1, band=band, frames=report)
    bad = [r for r in report if r["stale"]["margin"] + r["stale"]["gap"] + r["stale"]["row"]]
    print(f"{name} {title}: tap app {tt:.4f}, frames #{i0}..#{i1}, carousel band at rest {band}; frames with stale blocks {len(bad)}")
    for r in report:
        if not (r["stale"]["margin"] + r["stale"]["gap"] + r["stale"]["row"]) and "--frames" not in sys.argv: continue
        b = [x for x in r["boxes"]]
        fs = lambda v: "      -" if v is None else f"{v:+7.2f}"
        print(f"   #{r['frame']:<4} +{r['t'] * 1000:7.1f} ms  s_new {fs(r['s_new'])} ({r['lines_new']:3d} lines)  s_old {fs(r['s_old'])} ({r['lines_old']:3d})"
              f"  stale 6x6 blocks: margin {r['stale']['margin']:3d} gap {r['stale']['gap']:3d} row {r['stale']['row']:3d} (header {r['stale']['header']:2d})"
              + (f"  y {min(x[1] for x in b)}-{max(x[1] for x in b) + 6} x {min(x[0] for x in b)}-{max(x[0] for x in b) + 6}" if b else ""))
json.dump(out, open(f"{stem}.farjump.json", "w"))
