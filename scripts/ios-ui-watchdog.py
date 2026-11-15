#!/usr/bin/env python3
"""Watches a run of the iOS UI test plan for scripts/build-ios.sh, and ends one that no longer moves.

Two things have run the UI plan into the job's timeout, the tests failing nothing:

- the app never goes idle for XCTest. Before and after each tap or key, XCTest waits for the app's run loop and its
  animations to be idle; when the app never says its animations are, each wait ends after a minute ("App animations
  complete notification not received, will attempt to continue."), and a test of thirty steps takes half an hour and
  still passes. It holds for the rest of that app process's life;
- xcodebuild stays without a test running: before a simulator answers, or after the plan's last test.

The watchdog reads what the test runner writes while it runs (the result bundle's
Staging/*/Diagnostics/*/*/StandardOutputAndStandardError.txt, one per simulator) and judges:

- a stall: STALL_LIMIT idle waits timed out;
- silence: the test logs exist and none grew for SILENCE seconds, xcodebuild still running.

At the first timed-out idle wait, and again when it judges, it writes what it can find out into OUT (each best
effort): the simulators' states, the processes, a sample of xcodebuild, of the test runner and of the app, and the
animations on the app's layers, read through lldb (the animation the app never finished, if it has one). When it
judges, it writes OUT/verdict.txt, one line saying what it saw, and ends xcodebuild (SIGINT, so it closes the result
bundle, then SIGKILL): build-ios.sh fails the plan with that line.

It ends on its own when the process PARENT is gone; build-ios.sh ends it when xcodebuild returns.

Usage: scripts/ios-ui-watchdog.py --bundle UI.xcresult --parent PID --out DIR [--app NAME]
       scripts/ios-ui-watchdog.py --self-test
"""

import argparse
import glob
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

IDLE_TIMED_OUT = "App animations complete notification not received"
STALL_LIMIT = 5
SILENCE = 600
POLL = 5
# how long xcodebuild gets to close the result bundle after SIGINT
GRACE = 60
COMMAND_TIMEOUT = 120
VERDICT = "verdict.txt"

# the animations on every layer of every window of the app, the system's own windows included (the keyboard's)
ANIMATIONS_LLDB = """\
expr -l objc -O -- NSMutableString *o = (NSMutableString *)[NSMutableString new]; \
NSMutableArray *st = (NSMutableArray *)[NSMutableArray new]; \
id ws = [(id)NSClassFromString(@"UIWindow") \
performSelector:NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:") \
withObject:(id)1 withObject:(id)0]; \
for (id w in (NSArray *)ws) { \
[o appendFormat:@"window %@ hidden=%d scene=%@\\n", w, (int)[w isHidden], (id)[(id)[w windowScene] class]]; \
[st addObject:(id)[w layer]]; } \
int n = 0; \
while ((unsigned long)[st count]) { id l = (id)[st lastObject]; [st removeLastObject]; n++; \
for (id k in (NSArray *)[l animationKeys]) { id a = (id)[l animationForKey:k]; \
[o appendFormat:@"animation key=%@ %@ duration=%f repeat=%f removedOnCompletion=%d delegate=%@ on %@ of %@\\n", k, a, \
(double)[a duration], (float)[a repeatCount], (int)[a isRemovedOnCompletion], (id)[(id)[a delegate] class], l, \
(id)[l delegate]]; } \
id subs = (id)[l sublayers]; if (subs) [st addObjectsFromArray:(NSArray *)subs]; } \
[o appendFormat:@"%d layers\\n", n]; o
expr -l objc -O -- (id)[(id)[(id)NSClassFromString(@"UIApplication") sharedApplication] connectedScenes]
detach
"""


def runner_logs(bundle):
    """The test runner's logs of the run writing `bundle`, one per simulator: not the app's own output beside them."""
    pattern = os.path.join(bundle, "Staging", "*", "Diagnostics", "*", "*", "StandardOutputAndStandardError.txt")
    return sorted(glob.glob(pattern))


def read_progress(logs):
    """What the logs say so far: the idle waits that timed out, the test running last, and the logs' size."""
    stalls = 0
    size = 0
    test = ""
    for path in logs:
        try:
            with open(path, encoding="utf-8", errors="replace") as log:
                for line in log:
                    size += len(line)
                    if IDLE_TIMED_OUT in line:
                        stalls += 1
                    elif line.startswith("Test Case '") and "' started" in line:
                        test = line.split("'")[1]
        except OSError:
            continue
    return stalls, test, size


def judge(stalls, test, quiet_for, stall_limit=STALL_LIMIT, silence=SILENCE):
    """The verdict on a run with `stalls` timed-out idle waits whose logs last grew `quiet_for` seconds ago, or None."""
    where = " (last in " + test + ")" if test else ""
    if stalls >= stall_limit:
        return (
            "the app never went idle for XCTest: "
            + str(stalls)
            + ' waits for it timed out after a minute each ("'
            + IDLE_TIMED_OUT
            + '")'
            + where
        )
    if quiet_for is not None and quiet_for >= silence:
        return "xcodebuild ran on with no test moving for " + str(int(quiet_for)) + " s" + where
    return None


def pids(*pgrep_args):
    done = subprocess.run(["pgrep", *pgrep_args], capture_output=True, text=True, check=False)
    return [int(word) for word in done.stdout.split()]


def find_xcodebuild(parent):
    """The xcodebuild build-ios.sh (`parent`) runs under caffeinate, or None."""
    for caffeinate in pids("-P", str(parent), "-x", "caffeinate"):
        for pid in pids("-P", str(caffeinate), "-x", "xcodebuild"):
            return pid
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def save(out, name, command):
    """Writes what `command` prints into OUT/name: best effort, a diagnosis never fails the watchdog."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=COMMAND_TIMEOUT, check=False)
        text = done.stdout + done.stderr
    except (OSError, subprocess.SubprocessError) as error:
        text = "couldn't run " + " ".join(command) + ": " + str(error) + "\n"
    with open(os.path.join(out, name), "w", encoding="utf-8") as report:
        report.write(text)


def diagnose(out, label, xcodebuild, app):
    """What can be found out about a run that stopped moving, into OUT/label/."""
    where = os.path.join(out, label)
    os.makedirs(where, exist_ok=True)
    save(where, "simulators.txt", ["xcrun", "simctl", "list", "devices"])
    save(where, "processes.txt", ["ps", "-axo", "pid,ppid,etime,state,comm"])
    if xcodebuild is not None:
        save(where, "xcodebuild.sample.txt", ["sample", str(xcodebuild), "5"])
    for name in (app + "UITests-Runner", app):
        for pid in pids("-x", name):
            save(where, name + "-" + str(pid) + ".sample.txt", ["sample", str(pid), "5"])
    script = os.path.join(where, "animations.lldb")
    with open(script, "w", encoding="utf-8") as commands:
        commands.write(ANIMATIONS_LLDB)
    for pid in pids("-x", app):
        save(where, app + "-" + str(pid) + ".animations.txt", ["lldb", "--batch", "-p", str(pid), "-s", script])


def end(pid, grace=GRACE):
    """Ends xcodebuild: SIGINT lets it close the result bundle; SIGKILL when it doesn't go."""
    for sign, wait in ((signal.SIGINT, grace), (signal.SIGKILL, 5)):
        try:
            os.kill(pid, sign)
        except ProcessLookupError:
            return
        until = time.monotonic() + wait
        while time.monotonic() < until:
            # a child of this process (the self-test's) has to be reaped to be gone
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            if not alive(pid):
                return
            time.sleep(0.1)


def watch(bundle, out, target, parent_alive, app="NgTerm", stall_limit=STALL_LIMIT, silence=SILENCE, poll=POLL,
          grace=GRACE, examine=diagnose):
    """Watches the run until it ends (0) or is ended with a verdict (1). `target` finds xcodebuild's pid."""
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out, exist_ok=True)
    last_size = -1
    grew = time.monotonic()
    examined = False
    while parent_alive():
        stalls, test, size = read_progress(runner_logs(bundle))
        now = time.monotonic()
        if size != last_size:
            last_size = size
            grew = now
        xcodebuild = target()
        if stalls and not examined:
            examined = True
            examine(out, "first-idle-timeout", xcodebuild, app)
        # no log yet is the build and the simulator's boot, and no xcodebuild is the reports after the plan
        quiet_for = now - grew if size and xcodebuild is not None else None
        verdict = judge(stalls, test, quiet_for, stall_limit, silence)
        if verdict:
            with open(os.path.join(out, VERDICT), "w", encoding="utf-8") as report:
                report.write(verdict + "\n")
            examine(out, "verdict", xcodebuild, app)
            if xcodebuild is not None:
                end(xcodebuild, grace)
            return 1
        time.sleep(poll)
    return 0


def self_test():
    with tempfile.TemporaryDirectory() as temp:
        bundle = os.path.join(temp, "UI.xcresult")
        out = os.path.join(temp, "ui-watchdog")
        session = os.path.join(bundle, "Staging", "2_Test", "Diagnostics", "NgTermUITests-A", "NgTermUITests-B")
        os.makedirs(session)
        runner = os.path.join(session, "StandardOutputAndStandardError.txt")
        app_log = os.path.join(session, "StandardOutputAndStandardError-com.nickalie.ngterm.ios.txt")
        started = "Test Case '-[NgTermUITests.ChatTests testA]' started (Iteration 1 of 2).\n"
        waited = "    t =    24.10s     Wait for com.nickalie.ngterm.ios to idle\n"
        timed_out = "    t =    84.13s " + IDLE_TIMED_OUT + ", will attempt to continue.\n"

        def write(text):
            with open(runner, "w", encoding="utf-8") as log:
                log.write(text)

        # the app's own output beside the runner's log is not read
        with open(app_log, "w", encoding="utf-8") as log:
            log.write(timed_out * 50)
        write(started + waited)
        assert runner_logs(bundle) == [runner], runner_logs(bundle)
        assert runner_logs(os.path.join(temp, "none.xcresult")) == []
        assert read_progress([runner]) == (0, "-[NgTermUITests.ChatTests testA]", len(started + waited))
        write(started + (waited + timed_out) * 4)
        stalls, test, _ = read_progress([runner])
        assert (stalls, test) == (4, "-[NgTermUITests.ChatTests testA]")
        assert read_progress([os.path.join(temp, "gone.txt")]) == (0, "", 0)

        assert judge(4, test, 30) is None
        assert judge(0, "", None) is None
        said = judge(5, test, 0)
        assert said and "never went idle" in said and "5 waits" in said and "testA" in said, said
        said = judge(0, test, SILENCE)
        assert said and "no test moving for 600 s" in said and "testA" in said, said
        # before the first test's log, and with no xcodebuild, silence isn't judged
        assert judge(0, "", None, silence=0) is None

        seen = []

        def examine(where, label, xcodebuild, app):
            seen.append((label, xcodebuild, app))

        def run(**limits):
            # a stand-in for xcodebuild: a process the verdict has to end
            stand_in = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"],
                                        stderr=subprocess.DEVNULL)
            try:
                status = watch(bundle, out, lambda: stand_in.pid if stand_in.poll() is None else None, lambda: True,
                               poll=0.05, grace=5, examine=examine, **limits)
                ended = stand_in.poll() is not None
            finally:
                stand_in.kill()
                stand_in.wait()
            return status, ended

        # a stall: examined at the first timed-out wait, judged at the limit, xcodebuild ended
        write(started + (waited + timed_out) * 5)
        status, ended = run()
        assert status == 1 and ended, (status, ended)
        assert [label for label, _, _ in seen] == ["first-idle-timeout", "verdict"], seen
        with open(os.path.join(out, VERDICT), encoding="utf-8") as report:
            assert "never went idle" in report.read()

        # silence: the log stops growing
        seen.clear()
        write(started + waited)
        status, ended = run(silence=0.3)
        assert status == 1 and ended, (status, ended)
        assert [label for label, _, _ in seen] == ["verdict"], seen
        with open(os.path.join(out, VERDICT), encoding="utf-8") as report:
            assert "no test moving" in report.read()

        # a run that moves and ends is left alone: no verdict, the previous run's reports gone
        seen.clear()
        polls = iter([True, True, False])
        status = watch(bundle, out, lambda: None, lambda: next(polls), poll=0.05, examine=examine)
        assert status == 0 and not seen and os.listdir(out) == [], (status, seen, os.listdir(out))

        # one timed-out wait is examined and not judged
        write(started + waited + timed_out)
        polls = iter([True, True, False])
        status = watch(bundle, out, lambda: None, lambda: next(polls), poll=0.05, examine=examine)
        assert status == 0 and [label for label, _, _ in seen] == ["first-idle-timeout"], (status, seen)
        assert not os.path.exists(os.path.join(out, VERDICT))

        # diagnose never fails, whatever tools the host lacks
        diagnose(out, "here", None, "NoSuchAppOfThisName")
        assert os.path.isfile(os.path.join(out, "here", "simulators.txt"))
    print("ios-ui-watchdog self-test: ok")


def main(argv):
    if argv == ["--self-test"]:
        self_test()
        return 0
    parser = argparse.ArgumentParser(description="Watch a run of the iOS UI test plan (see the header).")
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--parent", required=True, type=int)
    parser.add_argument("--out", required=True)
    parser.add_argument("--app", default="NgTerm")
    args = parser.parse_args(argv)
    return watch(args.bundle, args.out, lambda: find_xcodebuild(args.parent), lambda: alive(args.parent), app=args.app)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
