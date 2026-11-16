# Implementation Notes

## 2026-07-18

- Scaffolded a Swift Package Manager executable for a macOS AppKit status bar app.
- The app reads recent OpenCode session directories from `~/.local/share/opencode/opencode.db` using the system `sqlite3` CLI.
- Recent directories are ordered by latest `session.time_updated` and displayed by the last path segment.
- OpenCode directory rows must be single absolute paths; malformed SQLite rows containing separators such as `|` are ignored.
- Selecting a project always opens a new Ghostty window at that directory. ProjectsBar no longer attempts to focus or reuse existing Ghostty windows.
- ProjectsBar does not use Accessibility APIs, AppleScript, or Ghostty window-title mutation.
- The menu includes a persisted `Run opencode on Open` toggle backed by `UserDefaults` key `runOpenCodeOnOpen`.
- When `Run opencode on Open` is enabled, ProjectsBar first checks whether the selected directory is already active in Ghostty. If it is already active, it opens a normal Ghostty window without running a command. If it is not active, it launches Ghostty via `open -na` with `-e /bin/zsh -lc 'cd <path> && exec opencode'`, because Ghostty's existing-instance Service does not expose a command parameter and direct `-e opencode` did not reliably preserve cwd.
- The build script ad-hoc signs the generated `.app` bundle so the bundle identifier and `Info.plist` are bound for macOS permissions.
- The menu shows `●` next to projects detected as active in Ghostty.
- The menu bar status item title is `● <N>`, where `N` is the number of listed recent projects detected as active in Ghostty.
- Active detection uses exact cwd paths from processes descended from Ghostty, with the descendant tree derived from `ps` and cwd paths read via `lsof`.
- `lsof -Fn` cwd results are parsed from `n<path>` records; non-path records are ignored.
- Active Ghostty state is refreshed at app launch and manual Refresh; the menu does not perform synchronous process scans while opening.
- Clicking a project opens a new Ghostty window using Ghostty's native macOS Service `New Ghostty Window Here` with a fresh named pasteboard containing a file URL inside the target directory.
- Ghostty's `New Ghostty Window Here` service opens the containing directory of the pasteboard item, so ProjectsBar passes a file inside the target directory rather than the directory itself. If no file exists, it creates `.projects-bar-open-here` in the target directory and passes that marker file.
- If the Ghostty Service cannot be invoked, the app shows an error and does not fall back. Silent fallback behavior was removed because it could open an incorrect directory.
- `scripts/build-app.sh` builds a release executable and packages `.build/ProjectsBar.app` with `LSUIElement` enabled so the app runs as a menu bar accessory.
- `scripts/install-login-item.sh` installs `~/Library/LaunchAgents/net.stupidtech.ProjectsBar.plist`, which opens the built app at login using LaunchAgent `RunAtLoad`.
- `scripts/uninstall-login-item.sh` unloads and removes that LaunchAgent.
- Process helpers drain stdout before waiting for exit to avoid deadlocking on commands with larger output, such as `ps`.

## 2026-08-16

- The menu now loads up to 30 recent projects and shows the most recent 10 directly. Remaining projects appear in a `More` submenu that opens when highlighted; the `More` item is omitted when there are no extra projects.
- Each project row shows the relative time since its most recent session update (`time_updated`, stored in `Date` milliseconds), appended inline to the project name (e.g. `1m`, `2h`, `3d`, `1w`).

## 2026-08-28

- The project list is now read from the opencode2 `project` table instead of the legacy `session` table.
- The query selects `worktree`, `name`, and `time_updated`, ordered by `time_updated DESC`. `worktree` is used as the project path and `time_updated` as its last activity time.
- Projects with a non-empty `name` column are displayed using that name; otherwise the row falls back to the last path segment of `worktree`, matching previous behavior. The `global` project (worktree `/`) renders an empty label, consistent with the previous "keep everything" filtering (only non-absolute paths are skipped).
- Rows are still parsed from the sqlite3 CLI `|`-separated output; exactly three columns are required, and NULL/empty names become `nil`.

## 2026-08-28 (revision)

- Corrected the source of project recency: `project.time_updated` is not a reliable "last activity" timestamp (it can lag real session activity by days), so the list is now built from `session_v2` instead.
- The query groups `session_v2` rows by `directory`, taking the most recent `time_updated` per directory (`ROW_NUMBER() ... PARTITION BY directory`), and orders by that latest session time. `session_v2.directory` is used as the project path.
- The optional display name is still pulled from the `project` table by joining on the project that owns the directory's latest session. In practice no `project.name` values are currently set, so rows fall back to the last path segment; the `global`-mapped directories (sessions with no dedicated project) render by their real path segment.
- Rows are parsed from the sqlite3 CLI `|`-separated output; exactly three columns (`directory`, `name`, `time_updated`) are required.
- Net effect: the list's order and relative times now reflect actual session activity (e.g. a project last touched today orders high), instead of the sometimes-stale `project.time_updated`.
- The project list refreshes automatically every time the menu opens. `AppDelegate` now conforms to `NSMenuDelegate`, `menu.delegate` is set at launch, and `menuWillOpen(_:)` calls `refreshProjects()` so the shown list is always current without needing the manual `Refresh` item. The manual `Refresh` item remains available.

## 2026-10-16

- Claude Code projects are now listed alongside OpenCode projects. They are read from `~/.claude/projects/<encoded-cwd>/*.jsonl`.
- Claude encodes the project cwd in the folder name by replacing every non-alphanumeric character with `-`, which is lossy. The real path is recovered by scanning the first 256 KB of each transcript (newest first) for a JSON line whose `cwd` re-encodes to the folder name. Folders with no matching `cwd` are skipped and logged.
- A Claude project's last activity time is the newest transcript file modification date in its folder.
- OpenCode and Claude projects are merged by exact path (keeping the most recent time and any OpenCode `name`), sorted by recency, and capped at 30 as before.
- The empty-state label is now `No Projects`. The `Run opencode on Open` toggle still applies to every project, including Claude ones.

## 2026-10-22

- Projects now open in [Scotty](https://scottyterm.com) instead of Ghostty. Ghostty support was removed entirely, including the `New Ghostty Window Here` Service, the `.projects-bar-open-here` marker file, and the self-spawned `--open-ghostty-window` helper mode.
- Clicking a project runs Scotty's bundled CLI, `/Applications/Scotty.app/Contents/Helpers/scotty --workspace <display name> --working-directory <path>`. Scotty adds the terminal to an open workspace with that exact name, or creates one in the active window. The `global` project (empty display name) uses its path as the workspace name.
- Scotty has no API to query or focus existing terminals, so clicking an already-open project adds another terminal to its workspace.
- The `Run opencode on Open` toggle was replaced by `Run claude on Open`, stored under the new `UserDefaults` key `runClaudeOnOpen`. The old `runOpenCodeOnOpen` value is not migrated.
- With `Run claude on Open` enabled and the project not active, the CLI is passed `-e /bin/zsh -lc 'exec claude'`. The login shell resolves `claude` from the user's PATH instead of Scotty's child environment; the CLI's `--working-directory` sets the cwd, so no `cd` is needed.
- The CLI can wait up to 30 seconds for Scotty, so it runs in a detached task. A non-zero exit shows the CLI's stderr in an error alert, with no fallback.
- Active detection now walks the process tree under `/Applications/Scotty.app/Contents/MacOS/ScottyApp` instead of Ghostty.
- `runProcessWithStatus` now also captures stderr.
- The CLI asks Scotty to open terminals with Apple Events, and macOS attributes those to ProjectsBar. `Info.plist` therefore declares `NSAppleEventsUsageDescription`; without it the launch failed with `Scotty rejected the launch.` macOS prompts for Automation permission the first time ProjectsBar opens a Scotty terminal.

## 2026-10-25

- Requires Scotty 0.5.0 or later. Projects open with `scotty terminal --name <project path> --if-existing focus --workspace <display name> --working-directory <path> [-- /bin/zsh -ilc claude]`.
- Each project gets one named Scotty terminal. Clicking a project focuses that terminal (activating its window and workspace) instead of adding another one; it is created only if no terminal with that name exists in the workspace. Names persist across Scotty session restore.
- The terminal name is the project path rather than the display name, so projects sharing a display name (and therefore a workspace) keep separate terminals.
- A focused terminal keeps its existing directory and command, so `Run claude on Open` only takes effect when the terminal is created. ProjectsBar no longer skips `claude` for projects detected as active.
- Terminals opened by earlier versions are unnamed and are not reused; the first click after upgrading creates a new named terminal.
- The `●` active markers are still derived from Scotty's process tree, since Scotty has no API to list terminals.

## 2026-10-25 (fix)

- `Run claude on Open` failed with `zsh:1: command not found: claude`: Scotty's child environment has a minimal PATH, and a login-only shell (`zsh -lc`) does not read `~/.zshrc`, where `claude` is typically added to PATH or aliased. The command is now `/bin/zsh -ilc claude`; the interactive login shell loads `~/.zshrc` like a normal terminal, and dropping `exec` lets aliases and shell functions resolve.

## 2026-10-25 (launcher extension)

- The `ProjectsBar` executable has a command-line mode for launcher integrations, handled before `NSApplication` starts:
  - `--list-json` prints the merged project list (same discovery, merge and 30-project cap as the menu) as a JSON array of `{ path, name, active, lastOpenedAt }`. `name` is the display name (the path for the `global` project), `active` comes from the Scotty process-tree scan, and `lastOpenedAt` is Unix milliseconds, omitted when unknown.
  - `--open <absolute path>` opens the project exactly like a menu click and blocks until the Scotty CLI exits, forwarding its exit status and stderr. It looks the path up in the project list to get the display name (workspace) and falls back to the last path segment. It honors the `Run claude on Open` setting, since the binary inside the bundle shares the app's `UserDefaults` domain.
  - Any other argument prints a usage error and exits 1. `-psn_…` arguments from LaunchServices are ignored, so a normal launch still starts the menu bar app.
- The Scotty launch was split into `runScottyTerminal` (blocking, shared by both modes) and `openScottyTerminal` (menu wrapper that runs it detached and shows an alert on failure).
- `extensions/projects-bar/` is a Raycast-format extension with one `Open Project` list command, built for Tinycast (which runs Raycast extensions in JavaScriptCore) and also usable in Raycast. It is a thin wrapper over the CLI mode so project discovery lives only in Swift.
  - The `ProjectsBar App` preference is the path to `ProjectsBar.app` (`~` is expanded).
  - The list is loaded with `execFileSync(... --list-json)` and validated with zod. Tinycast's runtime test harness returned empty stdout for a promisified async `execFile`, so the quick list call is synchronous; opening uses callback `execFile` because the Scotty CLI can wait up to 30 seconds.
  - Opening closes the palette first and reports failures with a HUD.
  - Build with `bun install && bun run build` (`ray build -e dist -o dist`), then install `dist/` in Tinycast via Settings → Extensions → Add from folder. Folder installs do not auto-update, so rebuild and re-add after changes.
- Opening from Tinycast runs the Scotty CLI as a descendant of Tinycast, so macOS may ask for Automation permission for Tinycast rather than ProjectsBar.
- Tinycast has no CLI. Its only external entry points are its URL schemes (which run commands of already-installed extensions) and settings import.
- `scripts/install-tinycast-extension.sh` installs the extension without the Settings UI. It builds `extensions/projects-bar` and copies `package.json`, the built `*.js` command bundles and `assets/` into `~/Library/Application Support/com.tinycast.app/extensions/projects-bar/`, which is what Tinycast's `ExtensionCatalog.install` (Add from folder) copies. The installed manifest gets `appPath`'s `default` set to the repo's `.build/ProjectsBar.app`, so no manual preference is needed. The source manifest has no default.
- Tinycast rescans that directory (`ExtensionManager.refresh`) when extensions are enabled at launch, when they are switched on, and when Settings → Extensions opens. Command bundles are read when a command runs, so a reinstall of an already-known extension applies on its next run. The script does not enable extensions (`extensionsEnabled`), since that goes through Tinycast's consent flow.

## 2026-10-30

- The launcher CLI is no longer capped: `--list-json` prints every known OpenCode and Claude Code project, and `--open` looks the path up in that full list. The Tinycast extension can therefore search all projects, not just the 30 most recent. The menu keeps its 30-project cap (10 shown, the rest under `More`).
- `loadAllRecentProjects`, `loadRecentProjects` and `mergeProjects` take an optional `limit`; `nil` means no limit (`LIMIT -1` in the SQLite query).

## 2026-11-02 (web app)

- The menu bar app now hosts a web app on port 7447 for the lifetime of the app (`WebServer.swift`, page in `WebApp.swift`). It uses the Network framework (`NWListener`) and a hand-written HTTP/1.1 parser, so the app stays dependency-free. The menu has an `Open Web App` item that opens `http://127.0.0.1:7447`. If the port cannot be bound, the app shows an error alert and does not fall back to another port.
- The page lists active Claude Code sessions and every known project (same discovery as `--list-json`, no cap), with a filter box. It updates live: `/events` is a server-sent events stream that receives the full state JSON whenever it changes. The server rebuilds the state every 3 seconds while at least one stream is open, plus right after a spawn or stop.
- `New session` on a project runs `claude --bg --remote-control <name> --name <name>` in the project directory (`POST /api/sessions {path}`). The path must be a known project. Sessions run under Claude Code's own background service, so they outlive ProjectsBar. `Stop` runs `claude stop <id>` (`POST /api/sessions/stop {id}`) and is only offered for background sessions.
- Sessions come from `claude agents --json` (interactive and background). A background session's claude.ai Remote Control URL is not in that JSON, so it is parsed from `claude logs <id>` (`https://claude.ai/code/session_…`). Found URLs are cached per id for the life of the app, because `claude logs` only keeps recent output. Misses are rechecked on every refresh during a session's first 2 minutes, then every 30 seconds. If ProjectsBar restarts after the URL has scrolled out of the logs, that session shows no link.
- All `claude` calls run through `/bin/zsh -ilc 'claude "$@"'` with the arguments as positional parameters, so `~/.zshrc` PATH entries and aliases apply (`claude` is an alias here) without shell quoting. If `claude agents --json` fails, the page shows the error.
- `runProcessWithStatus` takes an optional working directory and now gives child processes `/dev/null` as stdin.
- Tailscale access: the listener binds all interfaces, but `accept` drops every peer that is not loopback, in `100.64.0.0/10` or in `fd7a:115c:a1e0::/48`, so other LAN hosts cannot connect. There is no authentication beyond being on the tailnet.
- Because the API spawns processes, requests are checked against DNS rebinding and cross-site requests. The `Host` header must be an IP literal, `localhost`, a `*.ts.net` MagicDNS name or a single-label name. Non-GET requests must be `application/json`, which forces a CORS preflight that the server never approves, and any `Origin` must equal `http://<Host>`.
- Tailscale's Shields Up blocks all incoming tailnet connections, including this one, so it must be off on the Mac for remote access.

## 2026-11-02 (web app password)

- The web app requires a password. On first launch ProjectsBar generates one and writes it to `~/Library/Application Support/ProjectsBar/web-password` with mode 0600. It is 20 random characters from a 32-character lowercase alphabet without `i`, `l`, `o` and `1` (100 bits), in groups of 5 separated by `-`. To change it, edit the file and restart ProjectsBar; the password is read once at launch. An empty or unreadable file stops the web app from starting and shows an error alert.
- The menu has a `Copy Web App Password` item.
- `GET /` serves a login page until the browser has a valid session cookie. Every other route except `POST /api/login` and `POST /api/logout` returns 401 without one. The main page reloads to the login page when a request or the event stream gets a 401.
- `POST /api/login {password}` sets `projectsbar_session`: `HttpOnly`, `SameSite=Strict`, `Max-Age` 30 days, and no `Secure`, since the app is plain HTTP (Tailscale encrypts it). The cookie value is the hex HMAC-SHA256 of a fixed label keyed by the password (CryptoKit), so sessions survive app restarts and changing the password logs everyone out. Passwords and cookies are compared in constant time, and wrong passwords are answered after a 1 second delay.
- `POST /api/logout` clears the cookie.

## 2026-11-07 (new projects)

- The web app has a `New project` form. `POST /api/projects {name}` creates `~/environments/personal/pus/<name>` and spawns a Remote Control session in it, the same way `New session` does. The parent folder is the `newProjectsRoot` constant in `WebServer.swift`.
- Names must match `[A-Za-z0-9][A-Za-z0-9._-]{0,99}`, so they cannot contain `/`, start with `.` or escape the parent folder. An existing folder returns 409 and is never reused. If the spawn fails, the new folder is kept and the error starts with `Created <path>, but`.
- A new project is not in the project list until Claude Code writes its first transcript, so `POST /api/sessions` also accepts an existing folder directly inside `newProjectsRoot`.
- Claude Code refuses to start a background session in an untrusted folder ("Workspace not trusted"). ProjectsBar does not write trust into `~/.claude.json`. It relies on `~/environments/personal/pus` being trusted, which also covers new folders inside it (checked 2026-11-07). Without that trust, the page shows Claude's error.
- Command failures now fall back to stdout when stderr is empty, because `claude --bg` prints "Workspace not trusted" to stdout.

## 2026-11-16 (Scotty 0.7 CLI)

- Requires Scotty 0.7.2 or later. Scotty replaced `scotty terminal --name … --if-existing focus` with `scotty new --alias … --reuse`. Projects now open with `scotty new --alias <alias> --reuse --workspace <display name> --cwd <path> [-- /bin/zsh -ilc claude]`.
- Aliases must be unique across Scotty, at most 128 UTF-8 bytes and free of slashes, so the project path can't be used directly. `scottyAlias(forProjectPath:)` replaces the home directory with `~` and slashes with `:` (e.g. `~:code:my-app`). A path whose alias would exceed 128 bytes uses its last component (up to 100 bytes) plus `-` and the first 16 hex digits of the SHA-256 of the full path.
- `--reuse` focuses the terminal with that alias wherever it is, not only in the project's workspace, and never re-runs its command. Aliases persist across session restore.
- Terminals opened by earlier versions with `--name` have no alias, so the first click on such a project after upgrading opens a new terminal.
- The `●` active markers now come from `scotty ls --kind terminal --json` (each terminal's `workingDirectory`) instead of walking Scotty's process tree with `ps` and `lsof`. `scotty ls` never starts Scotty and takes about 70 ms. If it fails, the failure is logged and no projects are marked active. A project is active when a terminal's working directory equals its path exactly, as before.

## 2026-11-16 (Tinycast New Project)

- The Tinycast extension has a no-view `New Project` command with a required `name` argument. It validates the name with zod using the web app's rule (`[A-Za-z0-9][A-Za-z0-9._-]{0,99}`, trimmed), then runs `ProjectsBar --new-project <Projects Folder>/<name>` and reports failures with a HUD.
- `Projects Folder` is a command preference (default `~/Projects`, leading `~` expanded). `scripts/install-tinycast-extension.sh --projects-folder <path>` sets that default in the installed manifest only, so no personal path is committed.
- `--new-project <absolute path>` validates the last path component with the same rule (`isValidProjectName`, now shared with the web app), requires the parent folder to exist and the folder not to, creates it, then opens it exactly like `--open`, honoring `Run claude on Open`. The new folder has no transcripts yet, so it opens in a workspace named after the folder. If Scotty fails after the folder was created, the error starts with `Created <path>, but`.
- The web app's `New project` still uses its own `newProjectsRoot` constant; the Tinycast preference does not change it.
- `tsconfig.json` now includes `raycast-env.d.ts`, so commands can use the generated `Preferences.*` and `Arguments.*` types. With two commands, ray externalises shared dependencies into `dist/node_modules`, which the install script now copies.

## 2026-11-16 (Tinycast bundle ID)

- Tinycast 0.12 changed its bundle ID from `com.tinycast.app` to `com.abueammar.tinycast`, and its data moved to `~/Library/Application Support/com.abueammar.tinycast`. The install script now copies the extension into `.../com.abueammar.tinycast/extensions/projects-bar` and fails if that folder does not exist.
