import AppKit
import CryptoKit
import Foundation

private let runClaudeDefaultsKey = "runClaudeOnOpen"
private let maxRecentProjects = 30

private let scottyAppPath = "/Applications/Scotty.app"
private let scottyCLIPath = "\(scottyAppPath)/Contents/Helpers/scotty"

struct Project: Equatable, Sendable {
    let path: String
    let name: String?
    let lastOpenedAt: Date?

    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var projects: [Project] = []
    private var moreProjects: [Project] = []
    private var activeProjectPaths = Set<String>()
    private let webServer = WebServer()
    private var shouldRunClaudeOnOpen: Bool {
        UserDefaults.standard.bool(forKey: runClaudeDefaultsKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.title = "● 0"
        }

        menu.delegate = self
        statusItem.menu = menu
        refreshProjects()
        webServer.start { message in
            Task { @MainActor in showError(message) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshProjects()
    }

    @objc private func refreshProjects() {
        let recent = loadAllRecentProjects(limit: maxRecentProjects)
        projects = Array(recent.prefix(10))
        moreProjects = Array(recent.dropFirst(10))
        activeProjectPaths = loadScottyShellWorkingDirectories()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        logEvent("menu selected path=\(project.path)")
        openScottyTerminal(for: project, runClaude: shouldRunClaudeOnOpen)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if projects.isEmpty {
            let item = NSMenuItem(title: "No Projects", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for project in projects {
                menu.addItem(makeProjectItem(for: project))
            }

            if !moreProjects.isEmpty {
                let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                moreItem.submenu = makeProjectMenu(for: moreProjects)
                menu.addItem(moreItem)
            }
        }

        menu.addItem(.separator())
        let runClaudeItem = NSMenuItem(title: "Run claude on Open", action: #selector(toggleRunClaudeOnOpen), keyEquivalent: "")
        runClaudeItem.target = self
        runClaudeItem.state = shouldRunClaudeOnOpen ? .on : .off
        menu.addItem(runClaudeItem)
        let webAppItem = NSMenuItem(title: "Open Web App", action: #selector(openWebApp), keyEquivalent: "")
        webAppItem.target = self
        menu.addItem(webAppItem)
        let copyPasswordItem = NSMenuItem(title: "Copy Web App Password", action: #selector(copyWebAppPassword), keyEquivalent: "")
        copyPasswordItem.target = self
        menu.addItem(copyPasswordItem)
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshProjects), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openWebApp() {
        NSWorkspace.shared.open(webServerURL)
    }

    @objc private func copyWebAppPassword() {
        do {
            let password = try String(contentsOf: webPasswordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
        } catch {
            showError("Failed to read the web app password at \(webPasswordURL.path): \(error.localizedDescription)")
        }
    }

    @objc private func toggleRunClaudeOnOpen(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!shouldRunClaudeOnOpen, forKey: runClaudeDefaultsKey)
        rebuildMenu()
    }

    private func isScottyActive(for project: Project) -> Bool {
        activeProjectPaths.contains(project.path)
    }

    private func makeProjectItem(for project: Project) -> NSMenuItem {
        let isActive = isScottyActive(for: project)
        let timeSuffix = project.lastOpenedAt.map { " – \(relativeTimeString(from: $0))" } ?? ""
        let item = NSMenuItem(title: "\(isActive ? "● " : "")\(project.displayName)\(timeSuffix)", action: #selector(openProject(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = project
        item.toolTip = project.path
        return item
    }

    private func makeProjectMenu(for projects: [Project]) -> NSMenu {
        let submenu = NSMenu()
        for project in projects {
            submenu.addItem(makeProjectItem(for: project))
        }
        return submenu
    }

    private func updateStatusTitle() {
        let activeCount = projects.filter(isScottyActive).count
        statusItem.button?.title = "● \(activeCount)"
    }
}

/// A nil `limit` returns every known project, used by the launcher CLI so search covers all of them.
func loadAllRecentProjects(limit: Int?) -> [Project] {
    mergeProjects(
        loadRecentProjects(limit: limit) + loadRecentClaudeProjects(),
        limit: limit
    )
}

private func loadRecentProjects(limit: Int?) -> [Project] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let databasePath = "\(home)/.local/share/opencode/opencode.db"
    let query = """
    SELECT
      s.directory,
      p.name,
      s.time_updated
    FROM (
      SELECT
        directory,
        time_updated,
        ROW_NUMBER() OVER (PARTITION BY directory ORDER BY time_updated DESC) AS row_number
      FROM session_v2
      WHERE directory IS NOT NULL AND directory != ''
    ) s
    LEFT JOIN project p ON p.id = (
      SELECT project_id FROM session_v2 WHERE directory = s.directory ORDER BY time_updated DESC LIMIT 1
    )
    WHERE s.row_number = 1
    ORDER BY s.time_updated DESC
    LIMIT \(limit ?? -1);
    """

    let output = runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
        arguments: [databasePath, query]
    )

    return output
        .split(separator: "\n")
        .compactMap { line -> Project? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let path = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }
            let nameVector = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = nameVector.isEmpty ? nil : nameVector
            let lastOpenedAt = Double(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
                .map { Date(timeIntervalSince1970: $0 / 1000) }
            return Project(path: path, name: name, lastOpenedAt: lastOpenedAt)
        }
}

private func mergeProjects(_ projects: [Project], limit: Int?) -> [Project] {
    var byPath: [String: Project] = [:]
    for project in projects {
        guard let existing = byPath[project.path] else {
            byPath[project.path] = project
            continue
        }
        let existingDate = existing.lastOpenedAt ?? .distantPast
        let projectDate = project.lastOpenedAt ?? .distantPast
        byPath[project.path] = Project(
            path: project.path,
            name: existing.name ?? project.name,
            lastOpenedAt: max(existingDate, projectDate)
        )
    }
    return Array(
        byPath.values
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(limit ?? Int.max)
    )
}

/// Claude Code stores transcripts in `~/.claude/projects/<encoded-cwd>/<session>.jsonl`, where the
/// encoded name replaces every non-alphanumeric character of the cwd with `-`. The encoding is
/// lossy, so the real path is recovered from a `"cwd"` field whose encoding matches the folder name.
private func loadRecentClaudeProjects() -> [Project] {
    let fileManager = FileManager.default
    let projectsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    guard let directories = try? fileManager.contentsOfDirectory(
        at: projectsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return directories.compactMap { directoryURL -> Project? in
        guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let files = try? fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return nil
        }

        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                (url: url, modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        guard let latest = transcripts.first else { return nil }

        let encodedName = directoryURL.lastPathComponent
        guard let path = transcripts.lazy.compactMap({ claudeWorkingDirectory(in: $0.url, matching: encodedName) }).first else {
            logEvent("claude project skipped: no matching cwd for \(encodedName)")
            return nil
        }
        return Project(path: path, name: nil, lastOpenedAt: latest.modifiedAt)
    }
}

private func claudeWorkingDirectory(in transcriptURL: URL, matching encodedName: String) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: transcriptURL) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }

    for line in data.split(separator: UInt8(ascii: "\n")) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/"),
              encodeClaudeProjectName(cwd) == encodedName
        else {
            continue
        }
        return cwd
    }
    return nil
}

private func encodeClaudeProjectName(_ path: String) -> String {
    String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

/// Working directories of live Scotty terminals, from `scotty ls`, which never starts Scotty. A failure
/// (for example a denied Automation permission) is logged and treated as no open terminals.
private func loadScottyShellWorkingDirectories() -> Set<String> {
    let result = runProcessWithStatus(
        executableURL: URL(fileURLWithPath: scottyCLIPath),
        arguments: ["ls", "--kind", "terminal", "--json"]
    )
    guard result.status == EXIT_SUCCESS else {
        logEvent("scotty ls failed status=\(result.status) error=\(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        return []
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
          let terminals = object["terminals"] as? [[String: Any]]
    else {
        logEvent("scotty ls returned unexpected output=\(result.output)")
        return []
    }
    return Set(terminals.compactMap { $0["workingDirectory"] as? String }.filter { !$0.isEmpty })
}

/// Focuses the project's terminal in its Scotty workspace, or creates it, via the bundled `scotty` CLI.
/// The CLI can wait up to 30 seconds for Scotty to reply, so it runs off the main thread.
@MainActor
private func openScottyTerminal(for project: Project, runClaude: Bool) {
    Task.detached {
        let result = runScottyTerminal(for: project, runClaude: runClaude)
        guard result.status == EXIT_SUCCESS else {
            await MainActor.run {
                showError(result.errorOutput.isEmpty ? "Failed to open \(project.path) in Scotty (exit \(result.status))." : result.errorOutput)
            }
            return
        }
    }
}

/// Scotty aliases are unique, at most 128 UTF-8 bytes and can't contain slashes, so the path's slashes
/// become colons and the home directory becomes `~`, e.g. `~:code:my-app`. Longer paths keep their last
/// component and add a hash of the full path to stay unique.
func scottyAlias(forProjectPath path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var components = path.split(separator: "/").map(String.init)
    let homeComponents = home.split(separator: "/").map(String.init)
    if !homeComponents.isEmpty, components.starts(with: homeComponents) {
        components = ["~"] + components.dropFirst(homeComponents.count)
    }
    let alias = components.isEmpty ? ":" : components.joined(separator: ":")
    guard alias.utf8.count > 128 else { return alias }

    let hash = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let lastComponent = String(decoding: Data(components.last!.utf8).prefix(100), as: UTF8.self)
    return "\(lastComponent)-\(hash)"
}

/// The terminal's alias is derived from the project path, so projects sharing a display name (and
/// therefore a workspace) stay distinct. `--reuse` focuses an existing terminal without changing its
/// directory or command, so `claude` only runs when the terminal is created. Blocks until the CLI exits.
private func runScottyTerminal(for project: Project, runClaude: Bool) -> (output: String, errorOutput: String, status: Int32) {
    let workspace = project.displayName.isEmpty ? project.path : project.displayName
    var arguments = [
        "new",
        "--alias", scottyAlias(forProjectPath: project.path),
        "--reuse",
        "--workspace", workspace,
        "--cwd", project.path,
    ]
    if runClaude {
        // Scotty's child environment has a minimal PATH, and `claude` is typically set up in `~/.zshrc`,
        // so run it from an interactive login shell, as if typed in a normal terminal.
        arguments += ["--", "/bin/zsh", "-ilc", "claude"]
    }
    logEvent("scotty launch arguments=\(arguments)")

    let result = runProcessWithStatus(executableURL: URL(fileURLWithPath: scottyCLIPath), arguments: arguments)
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    logEvent("scotty exited status=\(result.status) output=\(output) error=\(errorOutput) path=\(project.path)")
    return (output, errorOutput, result.status)
}

/// New project folder names: no `/`, no leading `.`, so a name can't escape the projects folder.
func isValidProjectName(_ name: String) -> Bool {
    name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,99}/) != nil
}

private func isExistingDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

let projectNameRule = "Project names may only contain letters, digits, '.', '_' and '-', and must start with a letter or digit"

/// Command-line mode used by launcher extensions. Returns an exit code, or nil to start the menu bar app.
/// `--list-json` prints the merged project list; `--open <path>` opens a project the same way a menu
/// click does, honoring the `Run claude on Open` setting. `--new-project <path>` creates the folder (its
/// parent must exist, and the folder must not) and opens it the same way.
private func runCommandLine(_ arguments: [String]) -> Int32? {
    guard let command = arguments.first else { return nil }
    switch command {
    case "--list-json":
        let activePaths = loadScottyShellWorkingDirectories()
        let rows = loadAllRecentProjects(limit: nil).map { project -> [String: Any] in
            var row: [String: Any] = [
                "path": project.path,
                "name": project.displayName.isEmpty ? project.path : project.displayName,
                "active": activePaths.contains(project.path),
            ]
            if let lastOpenedAt = project.lastOpenedAt {
                row["lastOpenedAt"] = Int(lastOpenedAt.timeIntervalSince1970 * 1000)
            }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else {
            FileHandle.standardError.write(Data("Failed to encode projects\n".utf8))
            return EXIT_FAILURE
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return EXIT_SUCCESS
    case "--open":
        guard arguments.count == 2, arguments[1].hasPrefix("/") else {
            FileHandle.standardError.write(Data("Usage: ProjectsBar --open <absolute path>\n".utf8))
            return EXIT_FAILURE
        }
        let path = arguments[1]
        let project = loadAllRecentProjects(limit: nil).first { $0.path == path } ?? Project(path: path, name: nil, lastOpenedAt: nil)
        let result = runScottyTerminal(for: project, runClaude: UserDefaults.standard.bool(forKey: runClaudeDefaultsKey))
        if result.status != EXIT_SUCCESS {
            let message = result.errorOutput.isEmpty ? "Failed to open \(path) in Scotty (exit \(result.status))." : result.errorOutput
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        return result.status
    case "--new-project":
        guard arguments.count == 2, arguments[1].hasPrefix("/") else {
            FileHandle.standardError.write(Data("Usage: ProjectsBar --new-project <absolute path>\n".utf8))
            return EXIT_FAILURE
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let name = directory.lastPathComponent
        guard isValidProjectName(name) else {
            FileHandle.standardError.write(Data("\(projectNameRule)\n".utf8))
            return EXIT_FAILURE
        }
        // The parent folder must already exist, so a mistyped projects folder fails instead of being created.
        let parent = directory.deletingLastPathComponent()
        guard isExistingDirectory(parent) else {
            FileHandle.standardError.write(Data("Projects folder \(parent.path) does not exist\n".utf8))
            return EXIT_FAILURE
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            FileHandle.standardError.write(Data("Failed to create \(directory.path): \(error.localizedDescription)\n".utf8))
            return EXIT_FAILURE
        }
        logEvent("cli created project path=\(directory.path)")
        let project = Project(path: directory.path, name: nil, lastOpenedAt: nil)
        let result = runScottyTerminal(for: project, runClaude: UserDefaults.standard.bool(forKey: runClaudeDefaultsKey))
        if result.status != EXIT_SUCCESS {
            let detail = result.errorOutput.isEmpty ? "Scotty exited with status \(result.status)." : result.errorOutput
            FileHandle.standardError.write(Data("Created \(directory.path), but failed to open it in Scotty: \(detail)\n".utf8))
        }
        return result.status
    default:
        FileHandle.standardError.write(Data("Unknown argument \(command). Use --list-json, --open <path> or --new-project <path>.\n".utf8))
        return EXIT_FAILURE
    }
}

private func relativeTimeString(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date).rounded())
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    return "\(days / 7)w"
}

@MainActor
private func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "ProjectsBar Error"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.runModal()
}

func logEvent(_ message: String) {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ProjectsBar.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"

    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: logURL.path),
       let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

@discardableResult
private func runProcess(executableURL: URL, arguments: [String]) -> String {
    runProcessWithStatus(executableURL: executableURL, arguments: arguments).output
}

func runProcessWithStatus(executableURL: URL, arguments: [String], currentDirectory: String? = nil) -> (output: String, errorOutput: String, status: Int32) {
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        return ("", "Failed to run \(executableURL.path): \(error.localizedDescription)", EXIT_FAILURE)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", String(data: errorData, encoding: .utf8) ?? "", process.terminationStatus)
}

// macOS passes `-psn_…` to apps launched by older LaunchServices paths; only our own flags enter CLI mode.
if let status = runCommandLine(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }) {
    exit(status)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
