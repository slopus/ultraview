# Video

Screen recordings of the demo and frame-by-frame checks on them. The
recordings answer what a person would see: a row that arrives blank, a
carousel card that isn't drawn yet, a frame the screen skipped, the keyboard
and the list out of step. The tools need a Mac with Xcode, XcodeGen and
ffmpeg to record; the analysis runs anywhere with Python 3, ffmpeg and Swift.

Recordings, logs and frame dumps stay out of the repo: everything is written
under `.context/` by default.

## What the demo provides

- `-listScenario <name>` (`Sources/UltraViewDemo/List/ListVideoScenario.swift`)
  runs a scripted scenario in the Lists screen (far jump, mutations, flings,
  keyboard, stream) or, with `touch`, waits for a UI test's real touches. It
  samples the lists' geometry every display frame and writes
  `Documents/video/<clip>.json`. `-listVideoViews YES` adds every content
  view after each main-thread commit, so a row whose contents land after its
  frame shows up even between two display frames. Without `-listScenario` the
  hook does nothing.
- `Tests/UltraViewVideoTests` holds the touch scenarios: feed flings, the far
  jump with real taps, the carousel drag, swipe-to-reply and swipe-delete,
  keyboard dismissal and return, typing, stream and send. Only the
  `UltraViewVideo` scheme (Release) builds them, and they skip unless the
  runner below sets their environment.

## Recording

`record.py` drives both. Use your own `--bundle` on a shared machine, so you
don't replace someone else's install.

```sh
# Simulator: simctl's recording, one file per clip or test
python3 Tools/Video/record.py --sim <udid> build
python3 Tools/Video/record.py --sim <udid> clips jump-keyframe-views jump-uiKit-views
python3 Tools/Video/record.py --sim <udid> build-tests
python3 Tools/Video/record.py --sim <udid> touch testVideoFeedFlings,testVideoChatSwipes keyframe,stepped,uiKit

# Device (or simulator): XCTest's own screen recording
DEVELOPMENT_TEAM=<team> python3 Tools/Video/record.py --device <udid> build-tests
python3 Tools/Video/record.py --device <udid> xctest testVideoFeedJump,testVideoKeyboardFastDismissal keyframe
```

The XCTest path patches the generated `.xctestrun`:
- `SystemAttachmentLifetime` and `UserAttachmentLifetime` are set to
  `keepAlways`, so recordings of passing tests are kept;
- `PreferredScreenCaptureFormat` is set to `screenRecording`.

It then exports the result bundle with `xcresulttool export attachments`.
Each test method gets one recording. The manifest's timestamp for it is when
recording started, which `record.py` writes into the app's log as
`host.recordingStartedWall`.

On a simulator both kinds of recording are H.264 with a variable frame rate:
one frame per screen change, with time stamps in 1/600 s. Check a new
recording with `vidcadence.py` before you read frames as composites.

## Analysis

| Tool | What it reports |
|---|---|
| `rq.py <mp4> <json>` | blank or text-less rows, undrawn carousel cards, skipped display frames while moving (`--carousel` measures the cards' motion) |
| `process.sh <mp4> <json> <dir>` | trims to the scenario and runs `analyze-video.swift`: list motion against the logged model, hitches, jumps, pops, blank runs, keyboard and composer tracking, PNG sheets |
| `commitlag.py <dir>/<name>` | rows whose contents land in a later commit than their frame (needs `-listVideoViews`) |
| `farjump.py`, `widetitle.py`, `firstmove.py` | the far jump: stale pixels during travel, old titles after Top, tap to first change |
| `vidcadence.py <mp4>` | frame intervals and repeated frames |
| `trim.py` | cuts a recording with exact frame timestamps (used by `process.sh`) |

The pixel checks assume the demo's layout on a 390 × 844 pt screen. Their
docstrings give the exact thresholds.
