"""Cadence check for any screen recording, before claiming per-composite values:
container and stream rates, PTS interval histogram, and how many decoded frames are
repeats of the previous one (no pixel change), overall and inside a time window.
A recording that writes one frame per composite has no repeats while something moves
and irregular intervals; a fixed-rate one repeats frames or skips composites, and its
frames can't be called composites.
    python3 vidcadence.py <video> [from s] [to s] [--region y0 y1]   (region in fractions of height)"""
import collections, subprocess, sys
video = sys.argv[1]
args = list(sys.argv[2:])
if "--region" in args:
    i = args.index("--region"); del args[i:i + 3]
nums = [a for a in args if not a.startswith("--")]
t0 = float(nums[0]) if nums else 0.0
t1 = float(nums[1]) if len(nums) > 1 else 1e9
region = (0.0, 1.0)
if "--region" in sys.argv:
    i = sys.argv.index("--region"); region = (float(sys.argv[i + 1]), float(sys.argv[i + 2]))
probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
                        "stream=codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,nb_frames:format=duration",
                        "-of", "default=nw=1", video], capture_output=True, text=True, check=True).stdout
info = dict(l.split("=", 1) for l in probe.split() if "=" in l)
W, H = int(info["width"]), int(info["height"])
pts = [float(t.strip(",")) for t in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                                    "-of", "csv=p=0", video], capture_output=True, text=True, check=True).stdout.split()]
w, h = max(1, W // 4), max(1, H // 4)
proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"scale={w}:{h}:flags=area",
                         "-f", "rawvideo", "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
y0, y1 = int(region[0] * h), int(region[1] * h)
diffs, prev = [], None
while True:
    f = proc.stdout.read(w * h)
    if len(f) < w * h: break
    if prev is not None:
        a, b = f[y0 * w:y1 * w], prev[y0 * w:y1 * w]
        diffs.append(sum(abs(x - y) for x, y in zip(a[::2], b[::2])) / (len(a) / 2))
    else:
        diffs.append(None)
    prev = f
print(f"{video}: {info.get('codec_name')} {W}x{H}, r_frame_rate {info.get('r_frame_rate')}, avg {info.get('avg_frame_rate')}, "
      f"time_base {info.get('time_base')}, {len(pts)} frames in {info.get('duration')} s; decoded {len(diffs)}")
idx = [i for i in range(1, min(len(pts), len(diffs))) if t0 <= pts[i] <= t1]
iv = [round((pts[i] - pts[i - 1]) * 1000, 1) for i in idx]
hist = collections.Counter(round(x) for x in iv)
print(f"  window {t0:.3f}..{min(t1, pts[-1]):.3f} s: {len(idx)} frames; interval ms (rounded) histogram: "
      + ", ".join(f"{k}:{v}" for k, v in sorted(hist.items())))
same = [i for i in idx if diffs[i] is not None and diffs[i] < 0.05]
moving = [i for i in idx if diffs[i] is not None and diffs[i] >= 0.05]
print(f"  region y {region[0]:.2f}..{region[1]:.2f}: repeats (mean |diff| < 0.05) {len(same)}, changed {len(moving)}")
# Runs of changed frames: motion stretches, with their own interval statistics and repeats inside.
runs, cur = [], []
for i in idx:
    if diffs[i] is not None and diffs[i] >= 0.5: cur.append(i)
    elif cur:
        if len(cur) >= 4: runs.append(cur)
        cur = []
if len(cur) >= 4: runs.append(cur)
for r in runs[:20]:
    ivr = [(pts[i] - pts[i - 1]) * 1000 for i in r[1:]]
    inner = [i for i in range(r[0], r[-1] + 1) if diffs[i] is not None and diffs[i] < 0.05]
    print(f"  motion #{r[0]}..#{r[-1]} ({pts[r[0]]:.3f}..{pts[r[-1]]:.3f} s): {len(r)} changed frames, intervals ms "
          f"min {min(ivr):.1f} median {sorted(ivr)[len(ivr) // 2]:.1f} max {max(ivr):.1f}, repeats inside {len(inner)}")
if "--table" in sys.argv:
    for i in idx:
        print(f"   #{i:<5} pts {pts[i]:9.4f}  dt {(pts[i] - pts[i - 1]) * 1000:6.1f} ms  diff {diffs[i]:6.2f}")
