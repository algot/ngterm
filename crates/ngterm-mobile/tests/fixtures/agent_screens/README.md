# agent_screens

Raw PTY bytes of Claude Code 2.1.317 and Codex 0.166.0 at a phone (44x36), tablet (100x40) and desktop (160x48)
grid, with the byte offsets (`*.marks.json`) at which the idle prompt, a working turn, a permission dialog and
Claude's `AskUserQuestion` picker were on screen. How they were recorded and what each state shows:
`crates/ngterm-core/tests/fixtures/agent_chat/README.md`.

`claude-named-44x36` is Claude Code 2.1.325 at the phone's grid in a session with a name (`-n team-lead`), which it
draws into the rule over its prompt and, while a dialog is up, as one more row under the dialog. Its marks: `idle`,
`working`, `permission` (a `Bash` dialog), `question` (the picker), `idle_suggestion` and `idle_hr` (idle again, after
the picker and after a reply that drew a rule and a table), `idle_long_name` (renamed to a name too long for the row,
which loses the rule's left part and ends with `…`) and `idle_short_name` (a two-letter name).
