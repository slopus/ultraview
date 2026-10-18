"""Records the demo for frame analysis, on a simulator or a device. Needs a Mac with Xcode,
XcodeGen and ffmpeg; run it from the repository root. Recordings, the app's logs, build logs and
derived data go to --out (default .context/video).

Simulator, recorded by `simctl io recordVideo` (the app shares the host's clock):
    record.py --sim <udid> build                            Release demo, installed
    record.py --sim <udid> clips <name>...                  app-driven clips from clips.json
    record.py --sim <udid> build-tests                      the UltraViewVideo scheme, Release
    record.py --sim <udid> touch <test,...> <engine,...>    one recording per touch test
Simulator or device, recorded by XCTest itself (kept for passing tests too):
    record.py --device <udid> build-tests
    record.py --device <udid> xctest <test,...> <engine,...>
Tests are the methods of Tests/UltraViewVideoTests (testVideoFeedFlings, ...); engines are
keyframe, stepped and uiKit. Recordings land as <out>/sim-<prefix><clip>.mp4 and
<out>/<sim|device>-<prefix><touch|xctest>-<test>-<engine>.mp4, each with the app's log beside it
(.json), whose host.recordingStartedWall is the recording's start on the app's clock.

Options: --bundle <id> installs the demo under that bundle id (default dev.ultraview.video; pick
your own on a shared machine), --prefix <text> starts every clip name, --views logs every content
view per commit (-listVideoViews), --out <dir>. Device builds sign automatically
(-allowProvisioningUpdates) with DEVELOPMENT_TEAM from the environment and need an unlocked
keychain; the device must stay unlocked and awake. Before each device step the script waits while
another xcodebuild or devicectl process names the same device."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
where = parser.add_mutually_exclusive_group(required=True)
where.add_argument("--sim")
where.add_argument("--device")
parser.add_argument("--bundle", default="dev.ultraview.video")
parser.add_argument("--prefix", default="")
parser.add_argument("--out", default=".context/video")
parser.add_argument("--views", action="store_true")
parser.add_argument("command", choices=["build", "clips", "build-tests", "touch", "xctest"])
parser.add_argument("rest", nargs="*")
args = parser.parse_args()

env = dict(os.environ)
env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env["PATH"]
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
kind = "sim" if args.sim else "device"
target = args.sim or args.device
destination = f"platform=iOS Simulator,id={target}" if args.sim else f"platform=iOS,id={target}"
signing = [] if args.sim else ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration"] + ([f"DEVELOPMENT_TEAM={env['DEVELOPMENT_TEAM']}"] if env.get("DEVELOPMENT_TEAM") else [])
tests_data = out / f"DerivedData-{kind}-tests"
SUITE = "UltraViewVideoTests/ListVideoTouchTests"


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def run(command, **kwargs):
    kwargs.setdefault("env", env)
    return subprocess.run(command, **kwargs)


def xcodebuild(log_name, arguments, environment=None):
    """Runs xcodebuild into <out>/<log_name>, printing errors and our warnings; returns its status."""
    with open(out / log_name, "w") as handle:
        result = run(["xcodebuild", *arguments], env=environment or env, stdout=handle, stderr=subprocess.STDOUT)
    for line in (out / log_name).read_text(errors="replace").splitlines():
        if "error:" in line or ("warning:" in line and ("/Sources/" in line or "/Tests/" in line)):
            print(line)
    return result.returncode


def wait_for_device():
    """Waits while another xcodebuild or devicectl process works with the same device."""
    if args.sim:
        return
    mine, waited = os.getpid(), 0
    while True:
        listing = run(["ps", "-axo", "pid,ppid,command"], capture_output=True, text=True).stdout.splitlines()[1:]
        foreign = [line for line in listing if target in line and ("xcodebuild" in line or "devicectl" in line)
                   and int(line.split()[0]) != mine and int(line.split()[1]) != mine]
        if not foreign:
            return
        if waited % 60 == 0:
            log("waiting for other jobs on the device:", *[line.strip()[:120] for line in foreign])
        time.sleep(5)
        waited += 5


def boot():
    if args.sim:
        run(["xcrun", "simctl", "boot", target], stderr=subprocess.DEVNULL)
        run(["xcrun", "simctl", "bootstatus", target, "-b"], stdout=subprocess.DEVNULL)


def container():
    return run(["xcrun", "simctl", "get_app_container", target, args.bundle, "data"], capture_output=True, text=True).stdout.strip()


def app_log(name, destination_file):
    """Copies the app's log for clip `name` (Documents/video/<name>.json) to destination_file."""
    if args.sim:
        source = Path(container(), "Documents/video", f"{name}.json")
        if not source.exists():
            return False
        shutil.copyfile(source, destination_file)
        return True
    wait_for_device()
    return run(["xcrun", "devicectl", "device", "copy", "from", "--device", target, "--domain-type", "appDataContainer",
                "--domain-identifier", args.bundle, "--source", f"Documents/video/{name}.json", "--destination", str(destination_file)],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def finish_log(name, host):
    """Moves the app's log beside its recording, with the recording's start and the test's outcome in `host`."""
    path = out / f"{kind}-{name}.json"
    path.unlink(missing_ok=True)
    for _ in range(10):
        if app_log(name, path):
            document = json.loads(path.read_text())
            document["host"] = host
            path.write_text(json.dumps(document))
            return document
        time.sleep(1)
    return None


def start_recording(video):
    recorder = subprocess.Popen(["xcrun", "simctl", "io", target, "recordVideo", "--codec", "h264", "--force", str(video)],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in recorder.stdout:
        if "Recording started" in line:
            return recorder, time.time()
    return recorder, None


def stop_recording(recorder):
    recorder.send_signal(signal.SIGINT)
    try:
        recorder.wait(timeout=30)
    except subprocess.TimeoutExpired:
        recorder.kill()


def build():
    if not args.sim:
        sys.exit("build and clips run on a simulator; on a device use build-tests and xctest")
    boot()
    run(["xcodegen", "generate", "--quiet"], check=True)
    if xcodebuild("build-sim.log", ["build", "-project", "UltraView.xcodeproj", "-scheme", "UltraViewDemo", "-configuration", "Release",
                                    "-destination", destination, "-derivedDataPath", str(out / "DerivedData-sim"), f"DEMO_BUNDLE_ID={args.bundle}"]):
        sys.exit("build failed; see build-sim.log")
    install()
    run(["xcrun", "simctl", "status_bar", target, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
         "--cellularBars", "4", "--wifiBars", "3"], stderr=subprocess.DEVNULL)
    log("installed", args.bundle)


def install():
    run(["xcrun", "simctl", "install", target, str(out / "DerivedData-sim/Build/Products/Release-iphonesimulator/UltraViewDemoApp.app")], check=True)


def clip(entry):
    name = args.prefix + entry["clip"]
    arguments = ["-screen", "lists", "-listClip", name, "-perfRun", "NO", "-listProbe", "NO"]
    for key, value in entry["args"].items():
        arguments += [f"-{key}", str(value)]
    if args.views:
        arguments += ["-listVideoViews", "YES"]
    video = out / f"sim-{name}.mp4"
    video.unlink(missing_ok=True)
    if container():
        Path(container(), "Documents/video", f"{name}.json").unlink(missing_ok=True)
    run(["xcrun", "simctl", "terminate", target, args.bundle], stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    recorder, started = start_recording(video)
    run(["xcrun", "simctl", "launch", target, args.bundle] + arguments, capture_output=True, text=True)
    time.sleep(entry.get("duration", 10))
    stop_recording(recorder)
    document = finish_log(name, {"recordingStartedWall": started, "clock": "wall"})
    main = (document or {}).get("mainThread", {})
    log(name, "ok" if document else "NO LOG", f"p99Turn={main.get('p99TurnMilliseconds', 0):.2f}",
        f"maxTurn={main.get('maxTurnMilliseconds', 0):.1f}", f"video={video.stat().st_size if video.exists() else 0}")
    return document is not None


def clips(names):
    plan = json.loads((Path(__file__).parent / "clips.json").read_text())
    unknown = set(names) - {entry["clip"] for entry in plan}
    if unknown:
        sys.exit(f"not in clips.json: {sorted(unknown)}")
    # Touch tests install a build of their own under the same bundle id.
    install()
    failures = [entry["clip"] for entry in plan if (not names or entry["clip"] in names) and not clip(entry)]
    run(["xcrun", "simctl", "terminate", target, args.bundle], stderr=subprocess.DEVNULL)
    log("done; failures:", failures)


def build_tests():
    boot()
    run(["xcodegen", "generate", "--quiet"], check=True)
    wait_for_device()
    if xcodebuild(f"build-{kind}-tests.log", ["build-for-testing", "-project", "UltraView.xcodeproj", "-scheme", "UltraViewVideo",
                                              "-configuration", "Release", "-destination", destination, "-derivedDataPath", str(tests_data),
                                              f"DEMO_BUNDLE_ID={args.bundle}", *signing]):
        sys.exit(f"build failed; see build-{kind}-tests.log")
    log("built tests")


def test_environment(engine, clip_variable, clip_value):
    """The runner's environment for one engine: xcodebuild hands TEST_RUNNER_<name> to the tests as <name>."""
    variables = {"VIDEO_ENGINE": engine, clip_variable: clip_value}
    if args.views:
        variables["VIDEO_VIEWS"] = "1"
    return variables, {**env, **{f"TEST_RUNNER_{key}": value for key, value in variables.items()}}


def touch(tests, engines):
    """Each test in its own simctl recording."""
    if not args.sim:
        sys.exit("touch records a simulator; on a device use xctest")
    failures = []
    for engine in engines:
        for test in tests:
            name = f"{args.prefix}touch-{test}-{engine}"
            video = out / f"sim-{name}.mp4"
            video.unlink(missing_ok=True)
            if container():
                Path(container(), "Documents/video", f"{name}.json").unlink(missing_ok=True)
            _, environment = test_environment(engine, "VIDEO_CLIP", name)
            recorder, started = start_recording(video)
            status = xcodebuild(f"sim-{name}-test.log", ["test-without-building", "-project", "UltraView.xcodeproj", "-scheme", "UltraViewVideo",
                                                         "-configuration", "Release", "-destination", destination, "-derivedDataPath", str(tests_data),
                                                         "-collect-test-diagnostics", "never", "-parallel-testing-enabled", "NO",
                                                         f"-only-testing:{SUITE}/{test}", f"DEMO_BUNDLE_ID={args.bundle}"], environment)
            time.sleep(0.5)
            stop_recording(recorder)
            document = finish_log(name, {"recordingStartedWall": started, "clock": "wall", "test": test, "testStatus": status})
            log(name, "passed" if status == 0 else "TEST FAILED", "log" if document else "NO LOG")
            if status or document is None:
                failures.append(f"{test}-{engine}")
    log("done; failures:", failures)


def xctest(tests, engines):
    """All tests of one engine in one run, recorded by XCTest; recordings exported from the result bundle."""
    sources = sorted((tests_data / "Build/Products").glob("UltraViewVideo_*.xctestrun"), key=lambda p: p.stat().st_mtime)
    if not sources:
        sys.exit("no xctestrun; run build-tests first")
    failures = []
    for engine in engines:
        prefix = f"{args.prefix}xctest-"
        variables, environment = test_environment(engine, "VIDEO_CLIP_PREFIX", prefix)
        # Keep every attachment, record the screen rather than take screenshots, and
        # set the tests' environment in the file as well as through TEST_RUNNER_.
        config = plistlib.loads(sources[-1].read_bytes())
        if config.get("__xctestrun_metadata__", {}).get("FormatVersion") == 1:
            targets = [value for key, value in config.items() if key != "__xctestrun_metadata__" and isinstance(value, dict)]
        else:
            targets = [t for configuration in config.get("TestConfigurations", []) for t in configuration.get("TestTargets", [])]
        for entry in targets:
            entry["SystemAttachmentLifetime"] = "keepAlways"
            entry["UserAttachmentLifetime"] = "keepAlways"
            entry["PreferredScreenCaptureFormat"] = "screenRecording"
            for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                entry[key] = {**entry.get(key, {}), **variables}
        xctestrun = tests_data / f"Build/Products/video-{engine}.xctestrun"
        xctestrun.write_bytes(plistlib.dumps(config))
        bundle = out / f"{kind}-{prefix}{engine}.xcresult"
        exported = out / f"{kind}-{prefix}{engine}-attachments"
        shutil.rmtree(bundle, ignore_errors=True)
        shutil.rmtree(exported, ignore_errors=True)
        wait_for_device()
        status = xcodebuild(f"{kind}-{prefix}{engine}.log", ["test-without-building", "-xctestrun", str(xctestrun), "-destination", destination,
                                                             "-collect-test-diagnostics", "never", "-parallel-testing-enabled", "NO",
                                                             "-resultBundlePath", str(bundle)] + [f"-only-testing:{SUITE}/{t}" for t in tests], environment)
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(exported)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        manifest = json.loads((exported / "manifest.json").read_text()) if (exported / "manifest.json").exists() else []
        for test in tests:
            name = f"{prefix}{test}-{engine}"
            entry = next((e for e in manifest if e["testIdentifier"].split("/")[-1].removesuffix("()") == test), None)
            videos = sorted((a for a in (entry or {}).get("attachments", []) if a["exportedFileName"].endswith(".mp4")), key=lambda a: a["timestamp"])
            if not videos:
                log(name, "NO RECORDING")
                failures.append(f"{test}-{engine}")
                continue
            shutil.copyfile(exported / videos[0]["exportedFileName"], out / f"{kind}-{name}.mp4")
            document = finish_log(name, {"recordingStartedWall": videos[0]["timestamp"], "clock": "wall", "test": test, "testStatus": status,
                                         "recorder": "xctest"})
            log(name, "recorded", "log" if document else "NO LOG")
            if document is None:
                failures.append(f"{test}-{engine}")
        log(engine, "tests passed" if status == 0 else "TESTS FAILED")
        if status:
            failures.append(f"run-{engine}")
    log("done; failures:", failures)


if args.command == "build":
    build()
elif args.command == "clips":
    clips(args.rest)
elif args.command == "build-tests":
    build_tests()
elif args.command in ("touch", "xctest"):
    if len(args.rest) != 2:
        sys.exit(f"{args.command} <test,...> <engine,...>")
    (touch if args.command == "touch" else xctest)(args.rest[0].split(","), args.rest[1].split(","))
