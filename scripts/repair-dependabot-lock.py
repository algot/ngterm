#!/usr/bin/env python3
"""Repair the Cargo.lock edges a Dependabot cargo update moved, for .github/workflows/dependabot-lock-edges.yml.

Run from a checkout of the base branch (the one this script is in), which is all that is trusted: the pull request's
commit is data. Every mode first refuses a pull request that is not a Dependabot cargo branch whose only difference
from its merge base with the base branch is modified regular files named Cargo.lock or Cargo.toml, so the tree it
then checks out beside this one holds nothing else the base branch does not have.

Usage: scripts/repair-dependabot-lock.py fix HEAD_SHA BRANCH OUT
           run scripts/check-lock-edges.py --fix (this checkout's, with this checkout's cargo config and toolchain)
           over HEAD_SHA's tree and write the repaired Cargo.lock to OUT; no OUT when no edge moved
       scripts/repair-dependabot-lock.py commit HEAD_SHA BRANCH LOCK
           commit LOCK (a file, read as data) as HEAD_SHA's Cargo.lock on top of HEAD_SHA; needs no cargo
       scripts/repair-dependabot-lock.py workflows
           the workflows a Cargo.lock change starts on a pull request, one per line
       scripts/repair-dependabot-lock.py --self-test
`fix` and `commit` append `repaired=true` and `commit=SHA` to $GITHUB_OUTPUT when they produced one. Neither pushes.
"""

import contextlib
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRANCH_PREFIX = "dependabot/cargo/"
SHA = re.compile(r"^[0-9a-f]{40}$")
MAX_LOCK_BYTES = 8 << 20
# Dependabot rebases and force-pushes over a commit with this marker instead of leaving the pull request alone
MESSAGE = "build(deps): re-point the Cargo.lock edges the update moved\n\n[dependabot skip]\n"
IDENTITY = ["-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com"]
# a push with GITHUB_TOKEN starts no workflow, so the repair workflow dispatches these on the repaired branch
WORKFLOWS = ["android.yml", "conformance-gate.yml", "cross-platform.yml", "ios.yml", "linux.yml", "windows-installer.yml"]


class Refused(Exception):
    """The pull request is not one this script repairs."""


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, text=True).stdout


def gate(repo, head, branch):
    if not branch.startswith(BRANCH_PREFIX) or len(branch) == len(BRANCH_PREFIX):
        raise Refused(f"{branch!r} is not a Dependabot cargo branch")
    if not SHA.match(head):
        raise Refused(f"{head!r} is not a commit id")
    base = git(repo, "merge-base", "HEAD", head).strip()
    fields = git(repo, "diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")[:-1]
    for meta, path in zip(fields[::2], fields[1::2]):
        old_mode, new_mode, _, _, status = meta.lstrip(":").split(" ")
        named = path == "Cargo.lock" or path == "Cargo.toml" or path.endswith("/Cargo.toml")
        if not (named and status == "M" and old_mode == new_mode == "100644"):
            raise Refused(f"the pull request changes more than Cargo.lock and Cargo.toml files: {status} {path}")


@contextlib.contextmanager
def checkout(repo, head):
    with tempfile.TemporaryDirectory(prefix="dependabot-lock-") as parent:
        tree = Path(parent) / "tree"
        git(repo, "worktree", "add", "--quiet", "--detach", str(tree), head)
        try:
            yield tree
        finally:
            git(repo, "worktree", "remove", "--force", str(tree))


def only_the_lock_changed(tree):
    status = git(tree, "status", "--porcelain", "--untracked-files=all")
    if status not in ("", " M Cargo.lock\n"):
        raise RuntimeError(f"more than Cargo.lock changed:\n{status}")
    return bool(status)


def run_fix(repo, tree):
    script = Path(repo) / "scripts" / "check-lock-edges.py"
    subprocess.run([sys.executable, str(script), "--fix", "--manifest-path", str(tree / "Cargo.toml")], check=True)


def fix(repo, head, branch, out, run=run_fix):
    """Whether an edge had moved; the repaired lock is then at `out`."""
    gate(repo, head, branch)
    with checkout(repo, head) as tree:
        run(repo, tree)
        if not only_the_lock_changed(tree):
            return False
        Path(out).write_bytes((tree / "Cargo.lock").read_bytes())
        return True


def read_lock(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"{path} is not a regular file")
    if path.stat().st_size > MAX_LOCK_BYTES:
        raise RuntimeError(f"{path} is too large for a Cargo.lock")
    data = path.read_bytes()
    packages = tomllib.loads(data.decode()).get("package")
    if not isinstance(packages, list) or not packages:
        raise RuntimeError(f"{path} is not a Cargo.lock")
    return data


def commit(repo, head, branch, lock):
    """The commit that puts `lock` on top of `head`, or None when it is `head`'s lock already."""
    gate(repo, head, branch)
    data = read_lock(lock)
    with checkout(repo, head) as tree:
        (tree / "Cargo.lock").write_bytes(data)
        if not only_the_lock_changed(tree):
            return None
        git(tree, *IDENTITY, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", MESSAGE, "--", "Cargo.lock")
        return git(tree, "rev-parse", "HEAD").strip()


def output(line):
    print(line)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write(line + "\n")


def lock_workflows(directory):
    """The workflows whose pull_request trigger a Cargo.lock change matches, read from their text."""
    found = []
    for path in sorted(Path(directory).glob("*.yml")):
        text = path.read_text()
        trigger = re.search(r"^on:\n(.*?)^\S", text, re.MULTILINE | re.DOTALL)
        body = trigger.group(1) if trigger else ""
        pull = re.search(r"^  pull_request:\n(.*?)(?=^  \S|\Z)", body, re.MULTILINE | re.DOTALL)
        if pull and re.search(r'^      - Cargo\.lock$|paths: \["\*\*"', pull.group(1), re.MULTILINE):
            found.append((path.name, bool(re.search(r"^  workflow_dispatch:", body, re.MULTILINE))))
    return found


LOCK_TEXT = 'version = 4\n\n[[package]]\nname = "app"\nversion = "0.1.0"\ndependencies = [\n "sys {}",\n]\n'


def fixture(parent):
    """A base checkout on main and the commit of a Dependabot branch that moved the lock's edge."""
    repo = Path(parent) / "repo"
    repo.mkdir()
    git(repo, "init", "--quiet", "--initial-branch=main")
    (repo / "Cargo.toml").write_text('[package]\nname = "app"\nversion = "0.1.0"\n')
    (repo / "Cargo.lock").write_text(LOCK_TEXT.format("0.61.2"))
    (repo / "src").mkdir()
    (repo / "src" / "lib.rs").write_text("")
    snapshot(repo, "base")
    return repo


def snapshot(repo, message):
    git(repo, "add", "--all")
    git(repo, *IDENTITY, "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", message)
    return git(repo, "rev-parse", "HEAD").strip()


def branch_commit(repo, change, message="bump"):
    """A commit on a new branch off main that `change` made; main stays checked out."""
    git(repo, "checkout", "--quiet", "-b", "work", "main")
    change(repo)
    head = snapshot(repo, message)
    git(repo, "checkout", "--quiet", "main")
    git(repo, "branch", "--quiet", "-D", "work")
    return head


def restore_edge(_repo, tree):
    (tree / "Cargo.lock").write_text(LOCK_TEXT.format("0.61.2"))


def self_test():
    os.environ["GIT_CONFIG_GLOBAL"] = os.environ["GIT_CONFIG_SYSTEM"] = os.devnull
    branch = "dependabot/cargo/sys-0.61.3"
    with tempfile.TemporaryDirectory() as parent:
        repo = fixture(parent)
        out = Path(parent) / "Cargo.lock.repaired"
        moved = branch_commit(repo, lambda r: (r / "Cargo.lock").write_text(LOCK_TEXT.format("0.48.0")))
        (repo / "README").write_text("main moved on\n")
        main = snapshot(repo, "later on main")

        assert fix(repo, moved, branch, out, restore_edge) is True
        assert out.read_text() == LOCK_TEXT.format("0.61.2")
        assert git(repo, "worktree", "list").count("\n") == 1, "the data checkout was left behind"

        repaired = commit(repo, moved, branch, out)
        assert git(repo, "rev-parse", f"{repaired}^").strip() == moved
        assert git(repo, "diff", "--name-only", moved, repaired) == "Cargo.lock\n"
        assert git(repo, "show", f"{repaired}:Cargo.lock") == LOCK_TEXT.format("0.61.2")
        assert "[dependabot skip]" in git(repo, "log", "-1", "--format=%B", repaired)
        assert git(repo, "log", "-1", "--format=%an", repaired) == "github-actions[bot]\n"
        assert git(repo, "rev-parse", "HEAD").strip() == main, "the base checkout moved"
        assert git(repo, "status", "--porcelain") == ""

        out.unlink()
        assert fix(repo, repaired, branch, out, restore_edge) is False, "a repaired branch was repaired again"
        assert not out.exists()
        assert commit(repo, repaired, branch, repo / "Cargo.lock") is None

        def refused(head, name=branch):
            for call in (lambda: fix(repo, head, name, out, restore_edge), lambda: commit(repo, head, name, repo / "Cargo.lock")):
                try:
                    call()
                except Refused:
                    continue
                raise AssertionError(f"{name} at {head} was not refused")
            assert not out.exists()

        refused(moved, "dependabot/github_actions/actions/checkout-8")
        refused(moved, "dependabot/cargo/")
        refused(moved, "ci/dependabot/cargo/x")
        refused("--upload-pack=x")
        refused(branch_commit(repo, lambda r: (r / "src" / "lib.rs").write_text("fn f() {}\n")))
        refused(branch_commit(repo, lambda r: (r / "build.rs").write_text("fn main() {}\n")))
        refused(branch_commit(repo, lambda r: (r / "sub").mkdir() or (r / "sub" / "Cargo.toml").write_text("[package]\n")))
        refused(branch_commit(repo, lambda r: (r / "Cargo.lock").chmod(0o755)))
        refused(branch_commit(repo, lambda r: (r / "Cargo.lock").unlink() or (r / "Cargo.lock").symlink_to("README")))
        refused(branch_commit(repo, lambda r: (r / "Cargo.toml").unlink()))

        manifest = branch_commit(repo, lambda r: (r / "Cargo.toml").write_text('[package]\nname = "app"\nversion = "0.1.1"\n'))
        assert fix(repo, manifest, branch, out, restore_edge) is False

        def stray(_repo, tree):
            (tree / "Cargo.lock").write_text(LOCK_TEXT.format("0.60.2"))
            (tree / "build.rs").write_text("fn main() {}\n")

        for bad, lock in ((stray, None), (None, Path(parent) / "link"), (None, repo / "Cargo.toml"), (None, repo / "src")):
            (Path(parent) / "link").unlink(missing_ok=True)
            (Path(parent) / "link").symlink_to(repo / "Cargo.lock")
            try:
                fix(repo, moved, branch, out, bad) if bad else commit(repo, moved, branch, lock)
            except RuntimeError:
                assert not out.exists()
                continue
            raise AssertionError(f"accepted: {bad or lock}")
        assert git(repo, "worktree", "list").count("\n") == 1

    found = lock_workflows(ROOT / ".github" / "workflows")
    assert [name for name, _ in found] == WORKFLOWS, f"WORKFLOWS is not the workflows a Cargo.lock change starts: {found}"
    assert all(dispatch for _, dispatch in found), f"a workflow to dispatch has no workflow_dispatch trigger: {found}"
    print("repair-dependabot-lock: self-test passed")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if argv == ["workflows"]:
        print("\n".join(WORKFLOWS))
        return 0
    if len(argv) != 4 or argv[0] not in ("fix", "commit"):
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    mode, head, branch, path = argv
    try:
        if mode == "fix":
            if fix(ROOT, head, branch, path):
                output("repaired=true")
            else:
                print("Cargo.lock: no edge moved, nothing to repair")
        else:
            made = commit(ROOT, head, branch, path)
            if made:
                output(f"commit={made}")
            else:
                print("Cargo.lock: already the repaired one")
    except Refused as reason:
        print(f"not repairing: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
