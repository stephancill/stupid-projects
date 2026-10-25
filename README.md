# ProjectsBar

A macOS menu bar app that lists your recent [OpenCode](https://opencode.ai) and [Claude Code](https://claude.com/claude-code) projects and opens them as workspaces in [Scotty](https://scottyterm.com).

Native Swift/AppKit, no dependencies.

## Features

- Lists recent projects from OpenCode (`~/.local/share/opencode/opencode.db`) and Claude Code (`~/.claude/projects`), merged and sorted by last activity.
- Shows the 10 most recent projects with relative times (`5m`, `2h`, `3d`), with up to 20 more under `More`.
- Marks projects that already have a Scotty shell open with `●`, and shows the active count in the menu bar.
- Clicking a project focuses its terminal in a Scotty workspace named after the project, creating the workspace and terminal if needed.
- Optional `Run claude on Open` toggle starts `claude` when a project's terminal is first created.
- The list refreshes every time the menu opens.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode or Command Line Tools)
- Scotty 0.5.0 or later installed at `/Applications/Scotty.app` (uses its bundled `scotty` CLI)

## Build and run

```sh
scripts/build-app.sh
open .build/ProjectsBar.app
```

The build script produces an ad-hoc signed `.build/ProjectsBar.app` that runs as a menu bar accessory (no Dock icon).

## Launch at login

```sh
scripts/install-login-item.sh    # installs a LaunchAgent that opens the app at login
scripts/uninstall-login-item.sh  # removes it
```

## Tinycast / Raycast extension

`extensions/projects-bar` is a Raycast-format extension that lists the same projects in [Tinycast](https://github.com/abue-ammar/tinycast) (or Raycast) and opens them in Scotty. It calls the ProjectsBar binary's command-line mode:

```sh
.build/ProjectsBar.app/Contents/MacOS/ProjectsBar --list-json      # merged project list as JSON
.build/ProjectsBar.app/Contents/MacOS/ProjectsBar --open <path>    # open like a menu click
```

To build and install it into Tinycast (rerun after changes):

```sh
scripts/install-tinycast-extension.sh
```

The script copies the build into `~/Library/Application Support/com.tinycast.app/extensions/projects-bar`, like Tinycast's Add from folder does, and defaults the `ProjectsBar App` preference to this repo's `.build/ProjectsBar.app`. Extensions must be enabled in Tinycast's Settings → Extensions. Tinycast picks up a new install at launch or when that pane opens. To use the extension in Raycast instead, run `bun run build` in `extensions/projects-bar` and set the preference by hand.

## How it works

See [docs/implementation-notes.md](docs/implementation-notes.md) for details on project discovery, active-shell detection, and how Scotty terminals are opened.
