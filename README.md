# claude-banners-macos

> Native macOS notifications for Claude Code in VS Code — know when Claude finishes a turn or needs your attention, even when you're in another window.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2011%2B-blue)](#requirements)
[![Release](https://img.shields.io/github/v/release/tsenchenko/claude-banners-macos)](https://github.com/tsenchenko/claude-banners-macos/releases)

## The problem

Claude Code in the VS Code extension has no native desktop notifications. There's a built-in setting (`preferredNotifChannel`) but it only works in terminal emulators like iTerm2, Ghostty, or Kitty — not in the VS Code extension.

Switch to another app while Claude is running and you won't know when it:

- finishes a turn and is waiting for your next prompt
- asks a question or requests permission to run a tool

## The solution

This repo wires Claude Code's built-in **hooks** (`Stop`, `Notification`, `PermissionRequest`, and `PreToolUse`) into native macOS notifications. You get a banner in the corner of the screen the moment Claude returns control to you. The notification even shows the actual question text, so you know what's pending without switching apps.

**Click the notification** to bring the right VS Code window forward — matched by project folder, even if you have several VS Code windows open.

## Features

- Notification on `Stop` (Claude finishes its turn)
- Notification on `Notification` (idle prompts), showing the actual prompt text. Its `permission_prompt` type is skipped — it only repeats a prompt already shown, 15–30 s later
- Notification on `PreToolUse` for `AskUserQuestion` and `ExitPlanMode` — in-chat questions and plan-mode approval, which Claude Code does **not** dispatch through the `Notification` event
- **Tool-permission prompts** ("Allow reading from X?", "Allow running …?") via the dedicated `PermissionRequest` event, showing the tool and what it wants to run
- The question text is surfaced in the notification body, so you know what's being asked without switching apps
- **Click** the notification to focus the correct VS Code window — even with multiple windows open, it picks the one running this Claude Code session (via the `code` CLI, so no Accessibility permission is needed)
- **Focus-aware suppression** — no banner while you're already looking at that project's VS Code window (matched per-window, so a banner from *another* project still comes through). Best-effort: if Accessibility isn't granted it fails open and the banner simply shows
- A notification sound on every event
- Notifications for the same project replace each other instead of stacking
- Per-user install — no admin rights, no sudo
- Lives in `~/.claude/settings.json` with portable `"$HOME/.claude/hooks/notify.sh"` commands — so a `settings.json` synced across machines (e.g. via Google Drive) keeps working: each machine resolves `$HOME` to its own local hook scripts

## Requirements

- macOS 11 (Big Sur) or newer
- [Claude Code](https://claude.com/claude-code) in the **VS Code extension**. The CLI works for notifications too, but the click-to-focus action targets a VS Code window — there's no equivalent for terminal sessions
- `node` (already present if you run Claude Code) or `python3` — used to read the event JSON and update settings safely
- The VS Code `code` command on your machine (VS Code → Command Palette → "Shell Command: Install 'code' command in PATH"). Without it, click-to-focus falls back to just bringing VS Code forward
- Internet for first-time install (to fetch `terminal-notifier`)

## Install

One line in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/tsenchenko/claude-banners-macos/main/install.sh | bash
```

The installer will:

1. Install [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) — via Homebrew if you have it, otherwise a per-user copy into `~/.claude/bin/` (no admin)
2. Copy `notify.sh` and `focus-vscode.sh` to `~/.claude/hooks/`
3. Merge `Stop`, `Notification`, `PermissionRequest`, and `PreToolUse` hooks into `~/.claude/settings.json`, using portable `"$HOME/..."` commands (other keys and other hooks are preserved — including other commands that share a hook group with ours)
4. Send a test notification to confirm it works

After install, **restart any open Claude Code session** so it picks up the new hooks.

**Upgrading from a version with the "waiting detector"?** Re-run the installer. It drops the old `PostToolUse` hook and narrows `PreToolUse` back to `AskUserQuestion|ExitPlanMode`. Those hooks ran a script on every Read/Edit/Write, and each `PreToolUse` hook blocks its tool call until the script exits. On a machine that shares `settings.json` with Windows, every file operation also started PowerShell there.

If the test banner doesn't appear, open **System Settings → Notifications → terminal-notifier** and make sure it's allowed. Set its style to **Alerts** (instead of Banners) if you want notifications to stay on screen until you dismiss them, instead of disappearing on their own.

**Focus-aware suppression** reads the focused window's title to decide whether you're already looking at that project, which needs **Accessibility** permission for the app that runs the hook (System Settings → Privacy & Security → Accessibility). Until you grant it, notifications simply always show — nothing breaks.

## Customize

Open `~/.claude/hooks/notify.sh` and edit. Common tweaks:

- **Change the text** — find the `TITLE` / `SUBTITLE` / `BODY` lines and rewrite
- **Change the sound** — edit `-sound default` (any name from `/System/Library/Sounds`, or `-sound ''` for silent)
- **Show VS Code's icon** — add `-sender com.microsoft.VSCode` to the `args` array (note: this can change the click behavior on some macOS versions)

The hook reads the script fresh on every event, so no reinstall is needed after edits.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/tsenchenko/claude-banners-macos/main/uninstall.sh | bash
```

This removes the hook scripts, deletes the per-user `terminal-notifier` copy if the installer created one, and removes only our hook entries from `settings.json` (other keys and other hooks are preserved). A Homebrew-installed `terminal-notifier` is left alone — remove it with `brew uninstall terminal-notifier` if you want.

## How it works

```
┌──────────────┐   Stop / Notification / tool hooks   ┌──────────────┐
│ Claude Code  ├─────────────────────────────────────►│  notify.sh   │
└──────────────┘   (event JSON piped to script stdin)  └──────┬───────┘
                                                              │
                                                              ▼
                                                    ┌────────────────────┐
                                                    │ terminal-notifier  │──► macOS notification
                                                    └────────────────────┘
                                                              │
                                              user clicks the notification
                                                              ▼
                                              terminal-notifier  -execute
                                                              │
                                                              ▼
                                                    ┌────────────────────┐
                                                    │  focus-vscode.sh   │
                                                    └────────────────────┘
                                                              │
                                                              ▼
                                              `code <project folder>` focuses
                                              the VS Code window whose folder
                                              matches this Claude Code session
```

### Components

- **Hooks in `settings.json`** — Claude Code natively runs shell commands on lifecycle events. We attach to four, with portable `"$HOME/.claude/hooks/notify.sh"` commands so a synced `settings.json` works on every machine:
  - `Stop` — turn complete
  - `Notification` — idle prompts
  - `PermissionRequest` — the "Allow …?" tool-approval prompt (the dedicated event; `AskUserQuestion`/`ExitPlanMode` also arrive here and are skipped as duplicates)
  - `PreToolUse` matched on `AskUserQuestion|ExitPlanMode` only — in-chat questions and plan approval, with the question text. Keep this matcher narrow: every `PreToolUse` hook blocks its tool call until the script exits

  Note: at the user level Claude Code reads `~/.claude/settings.json` — **not** `settings.local.json` (that's a project-level file only). Global hooks placed in `settings.local.json` silently never fire.

  [Hook docs.](https://docs.claude.com/en/docs/claude-code/hooks)
- **`notify.sh`** — receives the event JSON on stdin, extracts the message / question / plan / permission detail and the project folder (`CLAUDE_PROJECT_DIR`, the session root, else the event `cwd`; using `node`, falling back to `python3`), and renders the notification through `terminal-notifier`. The click action carries the base64-encoded `cwd`. Before notifying, it checks whether you're already focused on this project's VS Code window — frontmost app via `lsappinfo` (no permission), then the focused window's title via System Events (needs Accessibility, fails open) — and suppresses the banner if so. Events it has no banner for are logged and ignored (they used to fall through to "Turn complete"). Logs to `$TMPDIR/claude-banners.log`.
- **`focus-vscode.sh`** — invoked when the notification is clicked. Decodes the project folder and runs `code <folder>`, which asks VS Code to focus the matching window and come to the foreground — no Accessibility permission required. If the `code` CLI isn't found it falls back to activating VS Code and a best-effort AppleScript window raise. Logs to `$TMPDIR/claude-focus.log`.

### Why `terminal-notifier` and `-execute`?

macOS lets a notification run a shell command directly: `terminal-notifier`'s `-execute` fires the moment you click the banner. So there's nothing to register — no custom URL protocol, no background listener, no indirection. The whole notification is clickable, and the click hands the project folder straight to `focus-vscode.sh`.

### Why `code <folder>` instead of raising the window ourselves?

Programmatically raising another app's specific window on macOS requires Accessibility permission (a TCC prompt). Handing the folder to the `code` CLI sidesteps that entirely: VS Code receives the open request and focuses its own window for that folder — correct even with several windows open, and no permission prompt.

## Tested on

- macOS 26.5 (Tahoe) — banners, click-to-focus, focus-aware suppression, and the full hook chain verified end-to-end
- VS Code with the Claude Code extension
- `terminal-notifier` 2.0.0 (Homebrew)
- `node` 20

Should work on macOS 11+ and with `python3` instead of `node`. PRs welcome if you hit issues elsewhere.

## Files in this repo

```
claude-banners-macos/
├── README.md
├── LICENSE
├── install.sh           # one-shot installer
├── uninstall.sh         # one-shot uninstaller
└── hooks/
    ├── notify.sh        # the notification renderer
    └── focus-vscode.sh  # the click-to-focus handler
```

The `hooks/` folder is the source of truth — `install.sh` copies (local clone) or downloads those files into `~/.claude/hooks/`.

## Credits

- [terminal-notifier](https://github.com/julienXX/terminal-notifier) by Eloy Durán / Julien Blanchard — native macOS notifications from the command line.

## License

MIT — see [LICENSE](LICENSE).
