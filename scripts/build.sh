#!/usr/bin/env bash
# Builds and tests on Linux (or any machine with a Darwin Swift SDK).
#
#   scripts/build.sh test   swift build + swift test for the host
#   scripts/build.sh ios    cross-build every target for iOS and the simulator
#   scripts/build.sh app    xtool dev build: the demo .app under xtool/
#   scripts/build.sh all    all of the above (default)
#
# Environment:
#   SWIFT            swift binary (default: swift on PATH)
#   SWIFT_SDKS_PATH  directory holding darwin.artifactbundle, if it isn't in
#                    SwiftPM's default location
#   TMPDIR           defaults to .context/tmp when the system one isn't writable
set -euo pipefail

cd "$(dirname "$0")/.."

swift=${SWIFT:-swift}
if [[ ! -w ${TMPDIR:-/tmp} ]]; then
    export TMPDIR=$PWD/.context/tmp
    mkdir -p "$TMPDIR"
fi
# xtool is an AppImage; this lets it run without FUSE.
export APPIMAGE_EXTRACT_AND_RUN=1

# SwiftPM's default build system doesn't target iOS from Linux; the native
# one works everywhere.
build_flags=(--build-system native)
sdk_flags=(--swift-sdk darwin)
if [[ -n ${SWIFT_SDKS_PATH:-} ]]; then
    sdk_flags+=(--swift-sdks-path "$SWIFT_SDKS_PATH")
fi

run_tests() {
    "$swift" build "${build_flags[@]}"
    "$swift" test "${build_flags[@]}"
}

run_ios() {
    "$swift" build "${build_flags[@]}" "${sdk_flags[@]}" --triple arm64-apple-ios
    "$swift" build "${build_flags[@]}" "${sdk_flags[@]}" --triple arm64-apple-ios-simulator
}

run_app() {
    xtool dev build
}

case ${1:-all} in
    test) run_tests ;;
    ios) run_ios ;;
    app) run_app ;;
    all) run_tests && run_ios && run_app ;;
    *) echo "usage: $0 [test|ios|app|all]" >&2; exit 2 ;;
esac
