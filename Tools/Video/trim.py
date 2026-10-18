"""Cuts [start, end] (seconds of the source's own frame timestamps)
out of a simulator recording and re-encodes it with exact timestamps.

recordVideo files carry B-frames and repeated timestamps, which make ffmpeg's
best-effort clock fall back to decode times: -ss/-to then cut the wrong
frames and shift the rest by seconds. Here the frames are decoded once, in
presentation order, paired with the timestamps ffprobe reports for them, and
written back through the concat demuxer with explicit durations.

    python3 trim.py <in.mp4> <out.mp4> <start> <end>   -> prints the source time of the first kept frame
"""
import os, shutil, subprocess, sys, tempfile

source, target, start, end = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", source],
                       capture_output=True, text=True, check=True).stdout.split()
times = [float(t.strip(",")) for t in probe]
work = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
try:
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-i", source, "-fps_mode", "passthrough", "-vf", "scale=586:-2", f"{work}/%06d.png"], check=True)
    count = len([f for f in os.listdir(work) if f.endswith(".png")])
    if count != len(times):
        sys.exit(f"decoded {count} frames but ffprobe lists {len(times)}")
    first = max([i for i, t in enumerate(times) if t <= start + 1e-4] or [0])
    last = max([i for i, t in enumerate(times) if t <= end] or [first])
    # Output times: the source's, from the first kept frame, nudged apart
    # where the source repeats a timestamp.
    tick = 1 / 600
    out = []
    for i in range(first, last + 1):
        t = round((times[i] - times[first]) / tick) * tick
        out.append(max(t, out[-1] + tick) if out else 0.0)
    with open(f"{work}/list.txt", "w") as handle:
        for k, i in enumerate(range(first, last + 1)):
            duration = out[k + 1] - out[k] if k + 1 < len(out) else 0.1
            handle.write(f"file '{work}/{i + 1:06d}.png'\noption framerate 600\nduration {duration:.6f}\n")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", f"{work}/list.txt", "-fps_mode", "passthrough",
                    "-video_track_timescale", "600", "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-bf", "0",
                    "-pix_fmt", "yuv420p", target], check=True)
    check = [float(t.strip(",")) for t in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                                                          "-of", "csv=p=0", target], capture_output=True, text=True).stdout.split()]
    worst = max(abs(a - b) for a, b in zip(check, out)) if check else 1
    if len(check) != len(out) or worst > 0.002:
        bad = [(k, round(a, 4), round(b, 4)) for k, (a, b) in enumerate(zip(check, out)) if abs(a - b) > 0.002][:5]
        print(bad, file=sys.stderr)
        sys.exit(f"timestamps not kept: {len(check)} frames for {len(out)}, worst {worst:.4f} s")
    print(f"{times[first]:.6f}")
finally:
    shutil.rmtree(work, ignore_errors=True)
