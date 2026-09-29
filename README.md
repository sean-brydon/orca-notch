# Orca Notch

A macOS notch bar for [Orca](https://github.com/stablyai/orca). It watches every agent across
local Orca plus all paired environments (`orca environment list`), tells you when one needs you, and
pulls down a mini Orca: agent list + live terminal screen + reply box.

## Install

    ./scripts/build-app.sh      # builds, installs to ~/Applications, launches

Requires the Orca app running with the `orca` CLI installed (`/usr/local/bin/orca`).

## Using it

- **Collapsed:** the notch grows ears when agents exist. Left = working count (blue), right = badge
  for agents that need you (orange = permission, yellow = waiting on you, green = finished, unseen).
- **New alert:** the notch peeks down for 5s with the agent + what it wants, and plays a sound.
- **Open:** hover the notch (closes when you leave), click it or press **⌥⌘O** (stays open; Esc or
  click outside to close).
- **Pull-down:** pick an agent → live screen (refreshes every 1s), quick keys (1/2/3, ⏎, esc, ⇧tab,
  arrows, ⌃C) and a reply box that sends text + Enter. "Open in Orca" focuses that terminal in Orca.
- Gear menu: sound, launch at login, clear finished, rescan environments, quit.

## How it works

Polls the `orca` CLI every 2s (~0.1s per call locally, ~0.5s per remote):
`worktree ps --json` for agent state (`working | blocked | waiting | done`), `terminal list` to map an
agent's `paneKey` (`tabId:leafId`) to a terminal handle, `terminal read --screen` / `terminal send`
for the pull-down. The screen is plain text, so `TerminalStyler` recolours it from agent TUI shapes.

Dev flags: `.build/debug/OrcaNotch --expanded` or `--peek-demo`.
