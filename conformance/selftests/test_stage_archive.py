"""`tools/stage-archive.sh`: a stage reaches another job with the build id of its live sessions' server still good."""

import os
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "tools" / "stage-archive.sh"
NATIVE = Path(__file__).parents[2] / "scripts" / "lib" / "native.sh"
# a modification time no whole-second archive keeps
MODIFIED_NS = 1_700_000_000_123_456_789


def archive(*args: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["bash", str(SCRIPT), *map(str, args)], capture_output=True, text=True, check=False)


@pytest.fixture
def stage(tmp_path: Path) -> Path:
    """A staged tree as scripts/stage.sh leaves it: the server, executable, and the id written for it."""
    stage = tmp_path / "built" / "conformance-stage"
    binary = stage / "bin" / "ngterm-session"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"server")
    binary.chmod(0o755)
    os.utime(binary, ns=(MODIFIED_NS, MODIFIED_NS))
    (stage / "share" / "ngterm").mkdir(parents=True)
    (stage / "share" / "ngterm" / "session-BUILD").write_text(f"{'a' * 64}\nbinary 6 {MODIFIED_NS}\n")
    return stage


@pytest.mark.parametrize(
    "modified_ns",
    [MODIFIED_NS, 1_700_000_000_000_456_789, 999_999_999, 1_700_000_000_000_000_000, 1_700_000_000_999_999_999],
)
def test_the_id_line_names_the_modification_time_to_the_nanosecond(tmp_path: Path, modified_ns: int) -> None:
    """Every digit, where a stat that formats the time through a float (uutils `%.9Y`) rounds the last ones."""
    binary = tmp_path / "ngterm-session"
    binary.write_bytes(b"server")
    os.utime(binary, ns=(modified_ns, modified_ns))
    if binary.stat().st_mtime_ns != modified_ns:
        pytest.skip("this filesystem keeps no nanoseconds")
    done = subprocess.run(
        ["bash", "-c", 'source "$1" && size_and_mtime_ns "$2"', "bash", NATIVE, binary],
        capture_output=True, text=True, check=False,
    )
    assert (done.returncode, done.stdout) == (0, f"6 {modified_ns}\n"), done.stderr


@pytest.mark.parametrize(
    ("seconds", "readable", "modified_ns"),
    [
        # 1700000000.999999900 as a float is 1700000001.0
        (1_700_000_001, "2023-11-14 22:13:20.999999900 +0000", 1_700_000_000_999_999_900),
        # the carry crosses a minute
        (1_700_000_040, "2023-11-14 22:13:59.999999999 +0000", 1_700_000_039_999_999_999),
        (1_700_000_000, "2023-11-14 22:13:20.123456789 +0000", MODIFIED_NS),
    ],
)
def test_the_id_line_takes_back_a_second_the_stat_rounded_up(seconds: int, readable: str, modified_ns: int) -> None:
    """The uutils `%Y` goes through a float too: a fraction just under a whole second carries into the seconds."""
    stat = f'stat() {{ [[ "$1" == --version ]] || echo "6 {seconds} {readable}"; }}'
    done = subprocess.run(
        ["bash", "-c", f'source "$1" && {stat} && size_and_mtime_ns binary', "bash", NATIVE],
        capture_output=True, text=True, check=False,
    )
    assert (done.returncode, done.stdout) == (0, f"6 {modified_ns}\n"), done.stderr


def test_the_id_line_refuses_seconds_the_readable_time_does_not_hold() -> None:
    stat = 'stat() { [[ "$1" == --version ]] || echo "6 1700000007 2023-11-14 22:13:20.000000000 +0000"; }'
    done = subprocess.run(
        ["bash", "-c", f'source "$1" && {stat} && size_and_mtime_ns binary', "bash", NATIVE],
        capture_output=True, text=True, check=False,
    )
    assert (done.returncode, done.stdout) == (1, ""), done.stderr


def test_an_unpacked_stage_keeps_what_its_build_id_names(tmp_path: Path, stage: Path) -> None:
    tar = tmp_path / "stage.tar"
    done = archive("pack", stage, tar)
    assert done.returncode == 0, done.stderr
    unpacked = tmp_path / "shard" / "conformance-stage"
    unpacked.mkdir(parents=True)
    (unpacked / "stale").write_text("of an earlier unpack")
    done = archive("unpack", tar, unpacked)
    assert done.returncode == 0, done.stderr
    binary = unpacked / "bin" / "ngterm-session"
    assert binary.stat().st_mtime_ns == MODIFIED_NS
    assert os.access(binary, os.X_OK)
    assert not (unpacked / "stale").exists()


def test_a_stage_whose_build_id_names_another_binary_is_refused(tmp_path: Path, stage: Path) -> None:
    """What a whole-second archive leaves: the id written for a binary of another modification time."""
    tar = tmp_path / "stage.tar"
    subprocess.run(["tar", "--format=ustar", "-C", stage.parent, "-cf", tar, stage.name], check=True)
    done = archive("unpack", tar, tmp_path / "shard" / "conformance-stage")
    assert done.returncode == 1
    assert "its session build id no longer names bin/ngterm-session" in done.stderr


def test_an_archive_with_more_than_the_stage_leaves_the_disk_as_it_was(tmp_path: Path, stage: Path) -> None:
    """Nothing lands beside the stage, and the stage of an earlier unpack stays."""
    (stage.parent / "other").write_text("beside the stage")
    tar = tmp_path / "stage.tar"
    subprocess.run(["tar", "--format=posix", "-C", stage.parent, "-cf", tar, stage.name, "other"], check=True)
    unpacked = tmp_path / "shard" / "conformance-stage"
    unpacked.mkdir(parents=True)
    (unpacked / "earlier").write_text("of an earlier unpack")
    done = archive("unpack", tar, unpacked)
    assert done.returncode == 1 and "does not hold conformance-stage alone: other" in done.stderr
    assert sorted(path.name for path in unpacked.parent.iterdir()) == ["conformance-stage"]
    assert (unpacked / "earlier").exists()
    tar.write_bytes(b"not a tar")
    done = archive("unpack", tar, unpacked)
    assert done.returncode == 1 and "is not a readable archive" in done.stderr
    assert (unpacked / "earlier").exists()


def test_a_stage_without_the_server_has_no_id_to_keep(tmp_path: Path) -> None:
    stage = tmp_path / "built" / "conformance-stage"
    (stage / "bin").mkdir(parents=True)
    (stage / "bin" / "ngterm").write_bytes(b"app")
    assert archive("pack", stage, tmp_path / "stage.tar").returncode == 0
    assert archive("unpack", tmp_path / "stage.tar", tmp_path / "shard" / "conformance-stage").returncode == 0
    assert (tmp_path / "shard" / "conformance-stage" / "bin" / "ngterm").read_bytes() == b"app"


def test_an_archive_of_another_directory_or_a_missing_one_is_refused(tmp_path: Path, stage: Path) -> None:
    tar = tmp_path / "stage.tar"
    assert archive("pack", stage, tar).returncode == 0
    done = archive("unpack", tar, tmp_path / "shard" / "conformance-stage-cov")
    assert done.returncode == 1 and "does not hold conformance-stage-cov alone: conformance-stage/" in done.stderr
    assert not (tmp_path / "shard").exists()
    done = archive("unpack", tmp_path / "none.tar", tmp_path / "shard" / "conformance-stage")
    assert done.returncode == 1 and "no archive at" in done.stderr
    done = archive("pack", tmp_path / "none", tar)
    assert done.returncode == 1 and "no staged tree at" in done.stderr
    assert archive("pack", stage).returncode == 2
