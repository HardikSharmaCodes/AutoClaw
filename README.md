<p align="center">
  <img src="docs/icon.png" width="128" alt="Claude Servant icon">
</p>

<h1 align="center">Claude Servant</h1>

<p align="center">
  A macOS menu bar app that watches your Claude usage limits and, when you're not using your capacity,<br>
  lets <b>Claude Code work on your projects by itself</b>: screenshot → improve → verify → commit → push.
</p>

---

## Why

Claude plans have usage windows that reset every few hours. When you're asleep, in class, or busy elsewhere, that capacity goes to waste.
Claude Servant notices when your session is free and asks:

> **"If you don't have any sessions to work on, should I work on existing projects?"**

Click **Yes** and Claude works through the projects you've added. For each one it reads past work, makes a few focused improvements, runs your lint, test and build scripts, and commits.

## Features

- **Session tracking**: your Claude Code sessions from the last 24 hours, with the active ones highlighted.
- **Usage tracking**: 5-hour and weekly usage bars with exact reset times, read from Claude Code itself.
- **Reset notifications**: when a used-up window resets, you get a notification with **Yes / No** buttons.
- **Idle nudges**: if Claude Code has been idle for 45 minutes, Servant offers to put it to work (at most once per window).
- **One-click projects**: press **+** in the menu bar to add any git repo. Web projects get their dev server detected automatically.
- **Visual verification**: for web projects, Servant starts the dev server and Claude takes before and after screenshots with headless Chrome.
- **Safe by default**:
  - It skips repos with uncommitted changes, so your work-in-progress is never auto-committed.
  - File edits are limited to the project folder.
  - Shell access is a short allowlist (git, lint/test/build, the screenshot helper). Everything else is denied automatically.
- **Paper trail**: every run appends to `SERVANT_LOG.md` in the project, and full logs land in `~/.claude/servant/logs/`.

## Requirements

- macOS 14 Sonoma or later
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude` works in your terminal)
- Xcode Command Line Tools (`xcode-select --install`) to build
- Google Chrome, Chromium, Edge or Brave for screenshots (optional)

## Install

```bash
git clone https://github.com/<you>/Claude_Servant.git
cd Claude_Servant
./scripts/install.sh
```

This:
1. builds `Claude Servant.app` and puts it in `~/Applications`;
2. installs two helper scripts into `~/.claude/servant/bin/`;
3. adds a Claude Code **status line** hook to `~/.claude/settings.json`. Claude Code gives that hook your rate-limit info, which is how Servant knows your usage. If you already have a status line, the script tells you how to chain it instead of overwriting yours;
4. launches the app. Look for the ✦ icon in your menu bar.

Allow notifications when macOS asks, and tick **Launch at login** in the menu so it's always there.

> Usage data refreshes whenever any Claude Code session is open. Open `claude` once after installing to populate it.

## Usage

1. Click ✦ in the menu bar, then **+** next to *Projects*, and pick one or more git repos.
2. In the settings window, adjust what Claude should focus on (or keep the default task), the dev server command, and git options.
3. Wait for the "session available" notification and click **Yes**. Or run things yourself with **Work on projects now** or a project's **Run** button.

The menu bar icon shows the state: ✧ idle, ✦ waiting for your answer, ⏳ limited, ⚙︎ working.

## What Claude is told to do

Every run wraps your per-project task with these rules:

1. Screenshot the running app (web projects).
2. Read `SERVANT_LOG.md` so it doesn't repeat earlier runs.
3. Do the task, keeping the scope small enough to finish.
4. Verify with the project's lint, test and build scripts.
5. Take an after screenshot and compare.
6. Log the run in `SERVANT_LOG.md`.
7. Commit only its own files, then push (configurable).
8. If verification can't be fixed, `git restore` and don't commit.

## Configuration

Everything lives in `~/.claude/servant/config.json`. You can edit it through the UI, or by hand under **More → Edit config…**. The app reloads it every 30 seconds.

| Key | Default | Meaning |
|---|---|---|
| `limitThresholdPercent` | `95` | Usage % at which a window counts as used up |
| `autoAskWhenIdle` | `true` | Offer to work when Claude Code is idle |
| `idleMinutesBeforeAsking` | `45` | How long to be idle before asking |
| `askCooldownHours` | `5` | Minimum time between idle nudges |
| `maxTurns` | `120` | Upper bound on agent turns per project |
| `baseAllowedTools` | git / npm / screenshot | Permission rules for every project |
| `projects[].extraAllowedTools` | | Extra rules for one project, e.g. `Bash(pytest:*)` |
| `projects[].requireCleanTree` | `true` | Skip a repo that has uncommitted changes |
| `projects[].autoPush` | `true` | Push after committing |

## ⚠️ A word of caution

Servant runs an AI agent **unattended** that commits and (by default) pushes to your repositories, using your Claude plan's usage.
- Use it on repos where an occasional bad commit is easy to revert.
- Consider turning off `autoPush`, or pointing projects at a branch.
- The allowlist limits shell commands, but `npm run build` and `npm test` run your project's own scripts, which Claude can edit. Treat this as "trusted repo" automation, not a sandbox.

## Uninstall

```bash
./scripts/uninstall.sh          # removes the app and the status line hook
./scripts/uninstall.sh --purge  # also deletes config and logs
```

## Development

```bash
swift build                    # debug build
./scripts/build_app.sh         # → build/Claude Servant.app
swift scripts/make_icon.swift  # regenerate the app icon
```

The code is a small SwiftUI app with no dependencies:

| File | Role |
|---|---|
| `App.swift` | Menu bar UI |
| `ProjectEditor.swift` | Project settings window |
| `ServantModel.swift` | State, limit tracking, asking, run queue |
| `ProjectRunner.swift` | git checks, dev server, headless `claude -p`, result parsing |
| `Usage.swift` | Reads usage and sessions |
| `Notifier.swift` | Actionable notifications |

## License

MIT
