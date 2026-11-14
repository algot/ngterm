#!/usr/bin/env bash
# Carry a staged tree (scripts/stage.sh layout) from the job that built it to the jobs that run it.
#
#   conformance/tools/stage-archive.sh pack STAGE_DIR TAR
#   conformance/tools/stage-archive.sh unpack TAR STAGE_DIR
#
# pack writes STAGE_DIR into TAR as a pax archive; unpack puts it back as STAGE_DIR (TAR holds the directory under
# its own name, so STAGE_DIR's must be the packed one's). The live sessions' server takes its staged build id
# (share/ngterm/session-BUILD) only for a binary of the size and modification time, to the nanosecond, the id was
# written for (crates/ngterm-session/src/build_id.rs). A plain artifact upload and tar's default format keep whole
# seconds, and the programs' mode bits go with the first: the run would then be of a build that verifies no id, not of
# the one an install has. So unpack exits 1 when the unpacked id no longer names its binary.
# Relative paths on Windows: GNU tar reads `C:` as a host.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/native.sh
source "$here/../../scripts/lib/native.sh"

usage() {
    sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# Whether the stage's session build id, when it has one, names the staged binary.
id_names_its_binary() {
    local stage="$1" id="$1/share/ngterm/session-BUILD" binary
    [[ -f "$id" ]] || return 0
    binary="$stage/bin/ngterm-session"
    [[ -f "$binary" ]] || binary+=".exe"
    [[ "$(sed -n 2p "$id")" == "binary $(size_and_mtime_ns "$binary")" ]]
}

[[ $# -eq 3 ]] || usage
case "$1" in
    pack)
        stage="$2" archive="$3"
        [[ -d "$stage" ]] || die "no staged tree at $stage"
        tar --format=posix -C "$(dirname "$stage")" -cf "$archive" "$(basename "$stage")"
        ;;
    unpack)
        archive="$2" stage="$3"
        [[ -f "$archive" ]] || die "no archive at $archive"
        mkdir -p "$(dirname "$stage")"
        rm -rf "$stage"
        tar -C "$(dirname "$stage")" -xf "$archive"
        [[ -d "$stage" ]] || die "$archive does not hold $(basename "$stage")"
        id_names_its_binary "$stage" \
            || die "$stage: its session build id no longer names bin/ngterm-session (size or modification time changed)"
        ;;
    *) usage ;;
esac
