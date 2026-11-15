#!/usr/bin/env python3
"""A stand-in Claude Code for the mobile e2e test (headless_e2e.rs): it runs in a pane's foreground as the real TUI
would, so the origin's agent record, `ngtermctl agent chat` and the phone's chat actions meet a pane that holds an agent.

- At start it writes the transcript (a copy of the backlog the test made from Task 1's fixture) and pipes the
  SessionStart payload to `ngtermctl agent hook claude SessionStart`, the pane and the private control socket named
  on the command line and no NGTERM_* in its environment, as the restore adapter does for the real agent.
- It draws Claude Code 2.1.317's idle screen by replaying Task 1's PTY capture recorded at the pane's grid
  (tests/fixtures/agent_screens/claude-<cols>x<rows>.bin up to its `idle` mark), again on every resize, so the phone's
  screen matcher reads the screen it was written against. A grid with no capture shows a line saying so until the
  next resize.
- It takes input as the TUI does: a bracketed paste or typed text goes into the composer, drawn where the capture
  parks the cursor (the composer's first column) in a plain style over the faint placeholder; Enter submits the
  composer: the prompt is appended to the transcript as Claude writes a user line, and shown above the prompt box as
  `> text`. Backspace drops a character. The replies to the terminal queries the capture makes, focus and mouse
  reports are read and dropped.
- Every cursor key it reads (an arrow, with or without modifiers) is appended to the `keys` file, one per line with
  its escape byte written `ESC`, in every state: what the test reads to tell which arrows reached the program.
- `/exit` submitted ends it: the screen modes are restored and it exits 0, with no SessionEnd, so the pane's
  foreground goes back to the shell and the origin clears the record on its own.
- The test moves it between states by writing the state's name to the `control` file and sending it SIGUSR1 (its pid
  is in the `pid` file): `idle`; `working`, a turn in progress (the capture's `working` screen), where a submitted
  prompt is absorbed into the turn as Claude Code 2.1.319+ writes it (a `queue-operation` and a `queued_command`
  attachment, no user line); `question`, the `AskUserQuestion` picker (the capture's `question` screen) of the
  `question` input, whose call Claude Code writes only once it is answered: a digit picks that option of its first
  question, writes the call and its result, and goes back to idle; `permission`, the `Bash` permission dialog (the
  capture's `permission` screen), where `1` (Yes) goes to `working` and writes nothing: the approved command runs on.

- With `agent` `codex` it stands in for Codex 0.167.2 instead: it reports through `agent hook codex`, draws the
  recorded `codex-questions` capture, and appends the recorded rollout's line `groups` as Codex wrote them:
  `permission` shows the approval dialog, where `y` (Yes, proceed) appends `approve` and goes back to idle;
  `question` appends `ask` (the `request_user_input` call) and shows its picker, where `2` (Green) appends `answer`.
  `exit` ends it, as Claude's `/exit` does.

- `--standalone [NAME]` is the Android e2e test's form (scripts/test-android-e2e.sh puts it on the machine's PATH as
  `e2e-claude`), started by hand in a pane's shell as a person starts Claude Code: it needs no config and no
  capture. It takes the pane, the session and the control socket from the pane's own `NGTERM_*` variables, starts a
  conversation with nothing said yet (an empty transcript under the home's `.claude/projects`), and draws Claude Code
  2.1.325's idle prompt for whatever grid the pane has: the box's rules, the upper one holding the session's NAME
  before its last `─` as Claude Code draws a session started with `-n` (`team-lead` when none is given), the
  input rows and the footer. A paste of four lines or more, or of over 800 characters, shows in the box as
  `[Pasted text #1 +N lines]` and is written to the transcript between `<pasted_content id="…">` lines, as
  Claude Code writes it; a shorter one shows as typed. Each prompt submitted shows above the box in full and gets the
  reply `ok`, except `Run this shell command with the Bash tool: COMMAND`: it writes the Bash call, tells the
  `PermissionRequest` hook, sets the pane `blocked` and draws Claude Code's permission dialog for COMMAND in place of
  the box. `1` (Yes) goes back to the box with a turn's spinner over it, the approved command running on with
  nothing written and no status reported, as Claude Code does until the call ends (the stand-in never ends it); Esc
  then interrupts it. `3` (No) or Esc on the dialog refuses it. Either end writes the call's error result and the
  turn's interrupt, shows `Interrupted` under the call and brings the prompt back, again with no status reported.

Usage: fake_agent.py CONFIG.json (the keys: agent, capture, transcript, backlog, payload, user_template, screens,
ngtermctl, socket, target, pane_id, control, pid, keys, question, groups), or fake_agent.py --standalone [NAME].
"""

import codecs
import copy
import datetime
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import tty
import uuid

# The row the submitted prompts start at: under the capture's banner at every recorded grid, above its prompt box.
HISTORY_TOP = 10
# The most submitted prompts shown.
HISTORY_ROWS = 6
# What the capture turns on, turned off again on exit.
RESTORE = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2031l\x1b[?2004l\x1b[0m\x1b[?1049l"
PASTE_START = "\x1b[200~"
PASTE_END = "\x1b[201~"
# An arrow key as a terminal sends it: CSI or SS3, any modifier parameters, final A to D.
CURSOR_KEY = re.compile(r"\x1b(?:\[[0-9;:]*|O)[ABCD]")


def load_captures(directory, prefix):
    """{(cols, rows): {state: (the capture's bytes up to the state's mark, the cursor's (row, col) where it parks it)}}
    of the captures named `<prefix>-<cols>x<rows>`."""
    captures = {}
    for name in sorted(os.listdir(directory)):
        grid = name[len(prefix) + 1 : -len(".marks.json")] if name.endswith(".marks.json") else ""
        if not (name.startswith(prefix + "-") and re.fullmatch(r"\d+x\d+", grid)):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as file:
            marks = json.load(file)
        with open(os.path.join(directory, name[: -len(".marks.json")] + ".bin"), "rb") as file:
            recorded = file.read()
        screens = {}
        for state, mark in marks["marks"].items():
            drawn = recorded[:mark]
            row, col = re.findall(rb"\x1b\[(\d+);(\d+)H", drawn)[-1]
            screens[state] = (drawn, (int(row), int(col)))
        captures[(marks["cols"], marks["rows"])] = screens
    return captures


def report(config):
    """Pipes the SessionStart payload to `ngtermctl agent hook`, addressed and aimed at the socket explicitly."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("NGTERM_")}
    command = [
        config["ngtermctl"], "agent", "hook", config["agent"], "SessionStart",
        "--target", config["target"], "--pane", "primary", "--pane-id", config["pane_id"],
        "--socket", config["socket"],
    ]
    with open(config["payload"], "rb") as payload:
        done = subprocess.run(command, stdin=payload, capture_output=True, env=env, check=False)
    if done.returncode != 0:
        sys.stderr.write(f"fake agent: agent hook failed ({done.returncode}): {done.stdout!r} {done.stderr!r}\r\n")
        sys.exit(1)


class Input:
    """The terminal's input as the TUI reads it: text, pastes and Enter; escape sequences (query replies, focus and
    mouse reports) dropped. With `escape`, an Esc read alone (the last byte of a read, nothing after it) is the Esc key,
    not the start of a sequence cut short."""

    def __init__(self, escape=False):
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pending = ""
        self.escape = escape

    def feed(self, data):
        self.pending += self.decoder.decode(data)
        actions = []
        while self.pending:
            taken = self.take(actions)
            if taken == 0:
                break  # an escape sequence or a paste not all read yet
            self.pending = self.pending[taken:]
        if self.escape and self.pending == "\x1b":
            actions.append(("escape", None))
            self.pending = ""
        return actions

    def take(self, actions):
        """Reads one item at the start of the input into `actions`: how much it took, 0 when it is cut short."""
        text = self.pending
        if text.startswith(PASTE_START):
            end = text.find(PASTE_END)
            if end < 0:
                return 0
            actions.append(("paste", text[len(PASTE_START) : end].replace("\r\n", "\n").replace("\r", "\n")))
            return end + len(PASTE_END)
        if text[0] == "\x1b":
            length = escape_length(text)
            if length and CURSOR_KEY.fullmatch(text[:length]):
                actions.append(("cursor", text[:length]))
            return length
        if text[0] in "\r\n":
            actions.append(("enter", None))
        elif text[0] in "\x7f\x08":
            actions.append(("backspace", None))
        elif text[0] >= " ":
            actions.append(("text", text[0]))
        return 1


def escape_length(text):
    """The length of the escape sequence `text` starts with, 0 when it is cut short."""
    if len(text) < 2:
        return 0
    kind = text[1]
    if kind == "[":
        for index in range(2, len(text)):
            if "\x40" <= text[index] <= "\x7e":
                return index + 1
        return 0
    if kind in "]P_^":
        # an OSC ends with BEL or ST, a DCS, APC or PM with ST
        bell = text.find("\x07", 2) if kind == "]" else -1
        st = text.find("\x1b\\", 2)
        ends = [end + 1 for end in [bell] if end >= 0] + [end + 2 for end in [st] if end >= 0]
        return min(ends) if ends else 0
    return 2


class Agent:
    # whether an Esc read alone is a key the agent takes ([`Input`])
    ESCAPE = False

    def __init__(self, config, captures):
        self.config = config
        self.captures = captures
        self.composer = ""
        self.history = []
        self.parent = None
        self.state = "idle"
        # what the control file said when last read: a resize's wake reads it again, and only a new word moves
        self.asked = ""

    def size(self):
        size = os.get_terminal_size(sys.stdout.fileno())
        return size.columns, size.lines

    def draw(self):
        cols, rows = self.size()
        capture = self.captures.get((cols, rows), {}).get(self.state)
        if capture is None:
            out(f"\x1b[?1049h\x1b[2J\x1b[Hfake agent: no recorded {self.state} screen at {cols}x{rows}".encode())
            return
        drawn, (row, col) = capture
        frame = bytearray(drawn)
        for index, line in enumerate(self.history[-HISTORY_ROWS:]):
            frame += f"\x1b[{HISTORY_TOP + index};1H\x1b[0m{f'> {line}'[:cols]}".encode()
        if self.composer:
            frame += f"\x1b[{row};{col}H\x1b[0m\x1b[K{self.composer}".encode()
        out(bytes(frame))

    def submit(self):
        text, self.composer = self.composer, ""
        if text.strip() == "/exit":
            return False
        if self.state == "working":
            self.absorb(text)
        else:
            self.write_prompt(text)
        self.history.append(" ".join(text.split()))
        return True

    def write_prompt(self, text):
        """Appends `text` to the transcript as Claude Code writes a typed prompt."""
        line = copy.deepcopy(self.config["user_template"])
        line["uuid"] = str(uuid.uuid4())
        line["parentUuid"] = self.parent
        line["promptId"] = str(uuid.uuid4())
        line["message"]["content"] = text
        line["timestamp"] = now()
        self.parent = line["uuid"]
        self.append([line])

    def stamped(self, line):
        line["timestamp"] = now()
        line["sessionId"] = self.config["user_template"]["sessionId"]
        return line

    def append(self, lines):
        with open(self.config["transcript"], "a", encoding="utf-8") as file:
            file.write("".join(json.dumps(line, separators=(",", ":")) + "\n" for line in lines))

    def absorb(self, text):
        """Takes `text` into the running turn, as Claude Code does with a prompt sent while it works."""
        session = self.config["user_template"]["sessionId"]
        source = str(uuid.uuid4())
        enqueue = {"type": "queue-operation", "operation": "enqueue", "timestamp": now(), "sessionId": session,
                   "content": text}
        remove = {"type": "queue-operation", "operation": "remove", "timestamp": now(), "sessionId": session,
                  "content": text, "reason": "absorbed_mid_turn", "commandUuid": source}
        attachment = self.stamped({
            "parentUuid": self.parent, "isSidechain": False, "type": "attachment", "uuid": str(uuid.uuid4()),
            "attachment": {"type": "queued_command", "prompt": text, "source_uuid": source, "commandMode": "prompt",
                           "origin": {"kind": "human"}, "timestamp": now(), "humanTurn": True},
        })
        self.parent = attachment["uuid"]
        self.append([enqueue, remove, attachment])

    def answer(self, digit):
        """Picks option `digit` of the question's first question: the call and its result, written together."""
        question = self.config["question"]["questions"][0]
        if not 1 <= digit <= len(question["options"]):
            return
        label = question["options"][digit - 1]["label"]
        call = self.stamped(copy.deepcopy(self.config["assistant_template"]))
        call["uuid"], call["parentUuid"] = str(uuid.uuid4()), self.parent
        call["message"]["id"] = "msg_e2e_question"
        call["message"]["content"] = [{"type": "tool_use", "id": QUESTION_CALL, "name": "AskUserQuestion",
                                       "input": self.config["question"]}]
        result = self.stamped(copy.deepcopy(self.config["user_template"]))
        result["uuid"], result["parentUuid"] = str(uuid.uuid4()), call["uuid"]
        result["message"]["content"] = [{"type": "tool_result", "tool_use_id": QUESTION_CALL,
                                         "content": f'User has answered your questions: "{question["question"]}"="{label}".'}]
        self.parent = result["uuid"]
        self.append([call, result])
        self.state = "idle"

    def group(self, name):
        """Appends the recorded rollout lines of group `name`."""
        with open(self.config["transcript"], "a", encoding="utf-8") as file:
            file.write("".join(line + "\n" for line in self.config["groups"][name]))

    def codex(self, action, value):
        """Codex's dialogs: the approval's `y`, the picker's `2`; anything else is left to the screen as it is."""
        if action == "text" and (self.state, value) in (("permission", "y"), ("question", "2")):
            self.group("approve" if self.state == "permission" else "answer")
            self.state = "idle"
        self.draw()
        return True

    def handle(self, action, value):
        """Applies one input action; False once the agent should exit."""
        if action == "cursor":
            if self.config.get("keys"):
                with open(self.config["keys"], "a", encoding="utf-8") as file:
                    file.write(value.replace("\x1b", "ESC") + "\n")
            return True
        if self.config["agent"] == "codex":
            return self.codex(action, value)
        if self.state == "question":
            if action == "text" and value.isdigit():
                self.answer(int(value))
            self.draw()
            return True
        if self.state == "permission":
            if action == "text" and value == "1":
                self.state = "working"
            self.draw()
            return True
        if action == "enter":
            if self.composer.strip() and not self.submit():
                return False
        elif action == "backspace":
            self.composer = self.composer[:-1]
        else:
            self.composer += value
        self.draw()
        return True

    def run(self, wake):
        stdin = sys.stdin.fileno()
        reader = Input(escape=self.ESCAPE)
        self.draw()
        while True:
            ready, _, _ = select.select([stdin, wake], [], [])
            if wake in ready:
                os.read(wake, 512)
                if not self.take_control():
                    return
                self.draw()
            if stdin in ready:
                data = os.read(stdin, 65536)
                if not data:
                    return
                for action, value in reader.feed(data):
                    if not self.handle(action, value):
                        return

    def take_control(self):
        """Moves to the state the test asked for, if it names one; False when it asked the program to exit."""
        try:
            with open(self.config["control"], encoding="utf-8") as file:
                state = file.read().strip()
        except FileNotFoundError:
            return True
        if state == self.asked:
            return True
        self.asked = state
        if state == "exit":
            return False
        if state == "question" and self.config["agent"] == "codex":
            self.group("ask")
        if state:
            self.state = state
        return True


class Standalone(Agent):
    """Claude Code 2.1.325's prompt drawn for any grid, in a session with a name (the module docs)."""

    PLACEHOLDER = 'Try "how does <filepath> work?"'
    ESCAPE = True
    # a prompt that asks for a shell command: the call goes to the permission dialog
    BASH = re.compile(r"Run this shell command with the Bash tool: (.+)", re.S)
    # what Claude Code writes as the result of a call the user refused or interrupted, and what it shows after either
    DENIED = ("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
              "edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to "
              "tell you how to proceed.")
    INTERRUPTED = "\u23bf  Interrupted \u00b7 What should Claude do instead?"

    def __init__(self, config, name):
        super().__init__(config, {})
        self.name = name
        self.pastes = []
        # what the agent showed under each prompt of `history`, by its index
        self.replies = {}
        # the Bash call asked for, while its dialog is up or the approved command runs: (tool use id, command)
        self.call = None
        self.calls = 0

    def take_control(self):
        return True

    def ctl(self, words, stdin=b""):
        """Runs `ngtermctl` on the pane, addressed and aimed at the socket explicitly, as the agent's hooks do."""
        env = {key: value for key, value in os.environ.items() if not key.startswith("NGTERM_")}
        config = self.config
        command = [config["ngtermctl"], *words, "--target", config["target"], "--pane", "primary",
                   "--pane-id", config["pane_id"], "--socket", config["socket"]]
        subprocess.run(command, input=stdin, capture_output=True, env=env, check=False)

    def ask(self, command):
        """Claude Code's call of the Bash tool for `command`, up to its permission dialog: the call written, the
        `PermissionRequest` hook told and the pane set `blocked`, as its status hooks do when the dialog opens."""
        self.calls += 1
        call_id = f"toolu_e2e_bash_{self.calls}"
        tool_input = {"command": command, "description": "An e2e command"}
        line = {"parentUuid": self.parent, "isSidechain": False, "type": "assistant", "uuid": str(uuid.uuid4()),
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": call_id, "name": "Bash",
                                                              "input": tool_input}]}}
        self.parent = line["uuid"]
        self.append([self.stamped(line)])
        payload = {"session_id": self.config["user_template"]["sessionId"],
                   "transcript_path": self.config["transcript"], "cwd": os.getcwd(), "permission_mode": "default",
                   "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": tool_input}
        self.ctl(["agent", "hook", "claude", "PermissionRequest"], json.dumps(payload).encode())
        self.ctl(["session", "status", "blocked"])
        self.call = (call_id, command)
        self.state = "permission"

    def stop_call(self):
        """The call refused (No, Esc on its dialog) or interrupted while it runs (Esc): its result an error, the turn
        over, as Claude Code writes them; the prompt is back. Like Claude Code, it reports no status for either."""
        call_id, _ = self.call
        result = self.stamped(copy.deepcopy(self.config["user_template"]))
        result["uuid"], result["parentUuid"] = str(uuid.uuid4()), self.parent
        result["message"]["content"] = [{"type": "tool_result", "content": self.DENIED, "is_error": True,
                                         "tool_use_id": call_id}]
        notice = self.stamped(copy.deepcopy(self.config["user_template"]))
        notice["uuid"], notice["parentUuid"] = str(uuid.uuid4()), result["uuid"]
        notice["message"]["content"] = [{"type": "text", "text": "[Request interrupted by user for tool use]"}]
        self.parent = notice["uuid"]
        self.append([result, notice])
        self.replies.setdefault(len(self.history) - 1, []).append("  " + self.INTERRUPTED)
        self.call = None
        self.state = "idle"

    def stand_in(self, index):
        return f"[Pasted text #{index + 1} +{self.pastes[index].count(chr(10))} lines]"

    def handle(self, action, value):
        if self.state == "permission":
            # 1 is Yes: the approved command runs on, and nothing is written until it ends; 3 (No) and Esc refuse it
            if action == "text" and value == "1":
                self.state = "working"
            elif (action, value) in (("text", "3"), ("escape", None)):
                self.stop_call()
            self.draw()
            return True
        if action == "escape":
            if self.state == "working" and self.call:
                self.stop_call()
                self.draw()
            return True
        if action == "paste" and (value.count("\n") >= 3 or len(value) > 800):
            self.pastes.append(value)
            self.composer += self.stand_in(len(self.pastes) - 1)
            self.draw()
            return True
        return super().handle(action, value)

    def submit(self):
        text, self.composer = self.composer, ""
        if text.strip() == "/exit":
            return False
        written = shown = text
        for index, paste in enumerate(self.pastes):
            block = f'\n\n<pasted_content id="{index + 1:04x}">\n{paste}\n</pasted_content id="{index + 1:04x}">\n'
            written = written.replace(self.stand_in(index), block)
            shown = shown.replace(self.stand_in(index), paste)
        self.pastes = []
        self.write_prompt(written)
        self.history.append(shown)
        bash = self.BASH.fullmatch(written.strip())
        if bash:
            command = bash.group(1).strip()
            self.replies[len(self.history) - 1] = [f"\u25cf Bash({command})"]
            self.ask(command)
            return True
        reply = {"parentUuid": self.parent, "isSidechain": False, "type": "assistant", "uuid": str(uuid.uuid4()),
                 "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}
        self.parent = reply["uuid"]
        self.append([self.stamped(reply)])
        self.replies[len(self.history) - 1] = ["\u25cf ok"]
        return True

    def draw(self):
        cols, rows = self.size()
        text = cols - 2
        said = []
        for number, prompt in enumerate(self.history):
            lines = [part[at : at + text] for part in prompt.split("\n") for at in range(0, max(len(part), 1), text)]
            said += [("\u276f " if index == 0 else "  ") + line for index, line in enumerate(lines)]
            said += ["", *self.replies.get(number, []), ""]
        if self.state == "permission":
            self.draw_dialog(said)
            return
        if self.state == "working":
            said.append("  \u23bf  Running\u2026")
        typed = [self.composer[at : at + text] for at in range(0, max(len(self.composer), 1), text)]
        # a running turn's spinner sits right over the box
        box = ["\u2722 Running\u2026 (esc to interrupt)", ""] if self.state == "working" else []
        box += ["\u2500" * (cols - len(self.name) - 3) + f" {self.name} \u2500"]
        box += [("\u276f " if index == 0 else "  ") + line for index, line in enumerate(typed)]
        box += ["\u2500" * cols, "  \u23f5\u23f5 auto mode on (shift+tab to cycle)"]
        above = said[-max(rows - len(box), 0) :] if rows > len(box) else []
        screen = above + [""] * (rows - len(box) - len(above)) + box
        frame = "\x1b[?1049h\x1b[?2004h\x1b[0m\x1b[2J"
        for index, line in enumerate(screen[-rows:]):
            frame += f"\x1b[{index + 1};1H{line[:cols]}"
        if not self.composer:
            frame += f"\x1b[{rows - 2};3H\x1b[2m{self.PLACEHOLDER[:text]}\x1b[0m"
        frame += f"\x1b[{rows - 2};{3 + len(typed[-1])}H"
        out(frame.encode())

    def draw_dialog(self, said):
        """Claude Code's Bash permission dialog in place of the prompt box, as its named session draws it: a rule,
        what it asks about (the command wrapped at the screen's edge), the question, the options, the footer and the
        session's titled rule."""
        cols, rows = self.size()
        _, command = self.call
        width = cols - 3
        dialog = ["\u2500" * cols, " Bash command", ""]
        dialog += ["   " + command[at : at + width] for at in range(0, max(len(command), 1), width)]
        dialog += ["   An e2e command", "", " Do you want to proceed?", " \u276f 1. Yes",
                   "   2. Yes, and don't ask again", "   3. No", "", " Esc to cancel \u00b7 Tab to amend",
                   "\u2500" * (cols - len(self.name) - 3) + f" {self.name} \u2500"]
        above = said[-max(rows - len(dialog), 0) :] if rows > len(dialog) else []
        screen = above + [""] * (rows - len(dialog) - len(above)) + dialog
        frame = "\x1b[?1049h\x1b[?2004h\x1b[0m\x1b[2J"
        for index, line in enumerate(screen[-rows:]):
            frame += f"\x1b[{index + 1};1H{line[:cols]}"
        out(frame.encode())


def standalone_config(home):
    """The config of a conversation with nothing said yet, in the pane the environment names."""
    session = str(uuid.uuid4())
    directory = os.path.join(home, ".claude", "projects", "-e2e-standalone")
    os.makedirs(directory, exist_ok=True)
    transcript = os.path.join(directory, f"{session}.jsonl")
    cwd = os.getcwd()
    payload = os.path.join(directory, f"{session}.session-start.json")
    with open(payload, "w", encoding="utf-8") as file:
        json.dump({"session_id": session, "transcript_path": transcript, "cwd": cwd, "hook_event_name": "SessionStart",
                   "source": "startup", "model": "claude-sonnet-5-5"}, file)
    open(transcript, "a", encoding="utf-8").close()
    return {
        "agent": "claude", "transcript": transcript, "payload": payload,
        "ngtermctl": shutil.which("ngtermctl"), "socket": os.environ["NGTERM_SOCKET"],
        "target": os.environ["NGTERM_SESSION_ID"], "pane_id": os.environ["NGTERM_PANE_ID"],
        "user_template": {"parentUuid": None, "isSidechain": False, "type": "user", "uuid": "", "promptId": "",
                          "message": {"role": "user", "content": ""}, "timestamp": "", "sessionId": session,
                          "cwd": cwd, "version": "2.1.325", "userType": "external"},
    }


QUESTION_CALL = "toolu_e2e_question"


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def out(data):
    view = memoryview(data)
    while view:
        view = view[os.write(sys.stdout.fileno(), view) :]


def main():
    if sys.argv[1] == "--standalone":
        config = standalone_config(os.path.expanduser("~"))
        agent = Standalone(config, sys.argv[2] if len(sys.argv) > 2 else "team-lead")
    else:
        with open(sys.argv[1], encoding="utf-8") as file:
            config = json.load(file)
        agent = Agent(config, load_captures(config["screens"], config["capture"]))
        os.makedirs(os.path.dirname(config["transcript"]), exist_ok=True)
        shutil.copyfile(config["backlog"], config["transcript"])
    report(config)
    # SIGWINCH wakes the loop through this pipe: a handler alone would not end the select
    wake, waker = os.pipe()
    os.set_blocking(waker, False)
    signal.set_wakeup_fd(waker)
    signal.signal(signal.SIGWINCH, lambda *_: None)
    signal.signal(signal.SIGUSR1, lambda *_: None)
    if "pid" in config:
        with open(config["pid"], "w", encoding="utf-8") as file:
            file.write(str(os.getpid()))
    stdin = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin)
    tty.setraw(stdin)
    try:
        agent.run(wake)
    finally:
        out(RESTORE)
        termios.tcsetattr(stdin, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
