#!/usr/bin/env bash
# Cargo's runner for the aarch64-apple-ios-sim target: runs a test binary (or any executable built for the simulator)
# inside the pinned phone simulator, IOS_SIM_PHONE_NAME on the IOS_SIMULATOR_RUNTIME of build/pins.env (both made by
# scripts/setup-ios.sh), through `xcrun simctl spawn`, and exits with the binary's exit status as simctl reports it:
# 128 + the signal when a signal ended it (an abort is 134), as a shell reports one.
#
# `scripts/setup-ios.sh --simulator` readies the simulator before each binary: it waits for the runtime disk images,
# makes the simulator again when it is gone and boots it when it isn't (`simctl bootstatus -b`, which waits until it
# is up). It is left booted, so the next binary of the same `cargo test` doesn't pay for another boot; `xcrun simctl
# shutdown ngterm-phone` stops it.
# The binary runs inside the simulator with the host's file system visible, so absolute paths baked in at compile
# time (`env!("CARGO_MANIFEST_DIR")`) resolve; its working directory is the simulator's data directory, not the
# package's. Its environment is the simulator's own plus what is forwarded: RUST_BACKTRACE and every RUST_TEST_*
# variable (simctl passes on SIMCTL_CHILD_<name> as <name>).
#
# Usage: CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUNNER="$PWD/scripts/ios-sim-runner.sh" \
#          cargo test -p <crate> --target aarch64-apple-ios-sim
#        scripts/ios-sim-runner.sh <executable> [args...]
#
# macOS only, with the iOS toolchain set up (scripts/setup-ios.sh; eval its --check exports for DEVELOPER_DIR).
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/ios-sim-runner.sh <executable> [args...]" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "scripts/ios-sim-runner.sh: the iOS simulator needs macOS; this host is $(uname -s)" >&2
  exit 1
fi

# shellcheck source=lib/native.sh
source "$(dirname "$0")/lib/native.sh" # sources build/pins.env too

executable="$1"
shift
[[ -f "$executable" ]] || die "no executable at $executable"
# simctl searches a relative path on the device too: hand it the host path
[[ "$executable" == /* ]] || executable="$PWD/$executable"

udid="$("$(dirname "$0")/setup-ios.sh" --simulator "$IOS_SIM_PHONE_NAME")" ||
  die "the simulator $IOS_SIM_PHONE_NAME on iOS $IOS_SIMULATOR_RUNTIME is not ready (see above)"

for name in $(compgen -e); do
  case "$name" in
    RUST_BACKTRACE | RUST_TEST_*) export "SIMCTL_CHILD_$name=${!name}" ;;
  esac
done

status=0
xcrun simctl spawn "$udid" "$executable" "$@" || status=$?
exit "$status"
