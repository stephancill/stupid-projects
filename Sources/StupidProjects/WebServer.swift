import CryptoKit
import Foundation
import Network

let webServerPort: UInt16 = 7447
let webServerURL = URL(string: "http://127.0.0.1:\(webServerPort)")!

private let refreshInterval: DispatchTimeInterval = .seconds(3)
private let sessionCookieName = "stupid_projects_session"
/// New projects created from the web app go here.
private let newProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("environments/personal/pus", isDirectory: true)
private let sessionCookieMaxAge = 30 * 24 * 60 * 60
let webPasswordURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/StupidProjects/web-password")

/// Web app for spawning Claude Code sessions with Remote Control. It lists projects and
/// active Claude sessions and pushes the state to open pages over server-sent events (`/events`).
/// Connection bookkeeping lives on `queue`; slow work (process spawning, project scans) runs on a
/// global queue so requests are not blocked behind a refresh.
final class WebServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.stupidtech.StupidProjects.web")
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var eventStreams: [ObjectIdentifier: NWConnection] = [:]
    private var lastState: Data?
    private var isRefreshing = false
    private var needsRefresh = false
    private var remoteURLLookups: [String: (url: String?, checkedAt: Date)] = [:]
    /// The session cookie value: an HMAC of a fixed label keyed by the password, so logins survive app
    /// restarts and are invalidated when the password changes.
    private var sessionToken = ""
    private var password = ""

    /// Calls `onFailure` if the password cannot be loaded or the listener cannot bind, for example when
    /// the port is already in use.
    func start(onFailure: @escaping @Sendable (String) -> Void) {
        let password: String
        do {
            password = try loadOrCreateWebPassword()
        } catch {
            onFailure("Failed to load the web app password at \(webPasswordURL.path): \(error.localizedDescription)")
            return
        }
        sessionToken = HMAC<SHA256>
            .authenticationCode(for: Data("stupid-projects-session".utf8), using: SymmetricKey(data: Data(password.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        self.password = password

        // Listens on all interfaces so the tailnet can reach it; `accept` drops every peer that is not
        // loopback or a Tailscale address.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: webServerPort)!)
        } catch {
            onFailure("Failed to start the web app on port \(webServerPort): \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logEvent("web server listening url=\(webServerURL.absoluteString)")
            case let .failed(error):
                logEvent("web server failed error=\(error)")
                onFailure("The web app on port \(webServerPort) stopped: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.eventStreams.isEmpty else { return }
            self.refresh()
        }
        timer.resume()
        self.timer = timer
    }

    private func accept(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint, isAllowedPeer(host) else {
            logEvent("web connection rejected endpoint=\(connection.endpoint)")
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(parsing: buffer) {
                self.handle(request, on: connection)
            } else if isComplete || error != nil || buffer.count > 1024 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        // Reject other hosts (DNS rebinding) and cross-origin writes, since the API spawns processes.
        guard let host = request.headers["host"], isAllowedHost(host) else {
            return respond(on: connection, status: "403 Forbidden", text: "Forbidden host")
        }
        if request.method != "GET" {
            if let origin = request.headers["origin"], origin != "http://\(host)" {
                return respond(on: connection, status: "403 Forbidden", text: "Forbidden origin")
            }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true else {
                return respond(on: connection, status: "415 Unsupported Media Type", text: "Expected application/json")
            }
        }

        switch (request.method, request.path) {
        case ("POST", "/api/login"):
            return login(request, on: connection)
        case ("POST", "/api/logout"):
            return respond(on: connection, status: "200 OK", json: [:], headers: [sessionCookie(value: "", maxAge: 0)])
        default:
            break
        }
        guard isAuthenticated(request) else {
            if request.method == "GET", request.path == "/" {
                return respond(on: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(loginHTML.utf8))
            }
            return respond(on: connection, status: "401 Unauthorized", text: "Log in first")
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(on: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(webAppHTML.utf8))
        case ("GET", "/api/state"):
            DispatchQueue.global().async {
                let state = self.loadState()
                self.respond(on: connection, status: "200 OK", contentType: "application/json", body: state)
            }
        case ("GET", "/events"):
            openEventStream(on: connection)
        case ("POST", "/api/sessions"):
            guard let body = jsonObject(request.body), let path = body["path"] as? String else {
                return respond(on: connection, status: "400 Bad Request", text: "Expected {\"path\": string}")
            }
            DispatchQueue.global().async {
                self.spawnSession(path: path, on: connection)
            }
        case ("POST", "/api/projects"):
            guard let body = jsonObject(request.body), let name = body["name"] as? String else {
                return respond(on: connection, status: "400 Bad Request", text: "Expected {\"name\": string}")
            }
            guard isValidProjectName(name) else {
                return respond(on: connection, status: "400 Bad Request", text: projectNameRule)
            }
            DispatchQueue.global().async {
                self.createProject(name: name, on: connection)
            }
        case ("POST", "/api/sessions/stop"):
            guard let body = jsonObject(request.body), let id = body["id"] as? String,
                  !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else {
                return respond(on: connection, status: "400 Bad Request", text: "Expected {\"id\": string}")
            }
            DispatchQueue.global().async {
                self.stopSession(id: id, on: connection)
            }
        default:
            respond(on: connection, status: "404 Not Found", text: "Not found")
        }
    }

    private func isAuthenticated(_ request: HTTPRequest) -> Bool {
        let cookies = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        return cookies.contains { cookie in
            guard cookie.hasPrefix("\(sessionCookieName)=") else { return false }
            return constantTimeEquals(String(cookie.dropFirst(sessionCookieName.count + 1)), sessionToken)
        }
    }

    /// Failed attempts are answered after a second to slow down guessing.
    private func login(_ request: HTTPRequest, on connection: NWConnection) {
        guard let body = jsonObject(request.body), let attempt = body["password"] as? String else {
            return respond(on: connection, status: "400 Bad Request", text: "Expected {\"password\": string}")
        }
        guard constantTimeEquals(attempt, password) else {
            logEvent("web login failed endpoint=\(connection.endpoint)")
            queue.asyncAfter(deadline: .now() + 1) {
                self.respond(on: connection, status: "401 Unauthorized", text: "Wrong password")
            }
            return
        }
        logEvent("web login succeeded endpoint=\(connection.endpoint)")
        respond(on: connection, status: "200 OK", json: [:], headers: [sessionCookie(value: sessionToken, maxAge: sessionCookieMaxAge)])
    }

    /// No `Secure` flag: the app is served over plain HTTP, which Tailscale's WireGuard tunnel encrypts.
    private func sessionCookie(value: String, maxAge: Int) -> String {
        "Set-Cookie: \(sessionCookieName)=\(value); Path=/; Max-Age=\(maxAge); HttpOnly; SameSite=Strict"
    }

    /// Spawns `claude --bg --remote-control <name>` in a known project directory. The session runs under
    /// Claude Code's own background service, so it outlives stupid projects.
    /// Spawns in a known project, or in a folder directly inside `newProjectsRoot`: a project created from the
    /// web app is not listed until its first transcript is written.
    private func spawnSession(path: String, on connection: NWConnection, failurePrefix: String = "") {
        let name: String
        if let project = loadAllRecentProjects(limit: nil).first(where: { $0.path == path }) {
            name = project.displayName.isEmpty ? project.path : project.displayName
        } else if isNewProjectFolder(path) {
            name = URL(fileURLWithPath: path).lastPathComponent
        } else {
            return respond(on: connection, status: "404 Not Found", text: "Unknown project \(path)")
        }
        let result = runClaude(["--bg", "--remote-control", name, "--name", name], directory: path)
        logEvent("web spawn path=\(path) status=\(result.status) output=\(result.output) error=\(result.errorOutput)")
        guard result.status == EXIT_SUCCESS,
              let match = result.output.firstMatch(of: /backgrounded · ([0-9a-f]+)/)
        else {
            return respond(on: connection, status: "500 Internal Server Error", text: failurePrefix + commandFailure("claude --bg", result))
        }
        respond(on: connection, status: "200 OK", json: ["id": String(match.1), "path": path])
        queue.async { self.refresh() }
    }

    /// Creates `<newProjectsRoot>/<name>` and spawns a session in it. An existing folder is an error, not
    /// reused. If the spawn fails the folder is kept, and the error says so.
    private func createProject(name: String, on connection: NWConnection) {
        let directory = newProjectsRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            return respond(on: connection, status: "409 Conflict", text: "\(directory.path) already exists")
        } catch {
            return respond(on: connection, status: "500 Internal Server Error", text: "Failed to create \(directory.path): \(error.localizedDescription)")
        }
        logEvent("web created project path=\(directory.path)")
        spawnSession(path: directory.path, on: connection, failurePrefix: "Created \(directory.path), but ")
    }

    private func stopSession(id: String, on connection: NWConnection) {
        let result = runClaude(["stop", id])
        logEvent("web stop id=\(id) status=\(result.status) output=\(result.output) error=\(result.errorOutput)")
        guard result.status == EXIT_SUCCESS else {
            return respond(on: connection, status: "500 Internal Server Error", text: commandFailure("claude stop", result))
        }
        respond(on: connection, status: "200 OK", json: ["id": id])
        queue.async { self.refresh() }
    }

    private func openEventStream(on connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let key = ObjectIdentifier(connection)
        eventStreams[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.eventStreams[key] = nil
            default:
                break
            }
        }
        // Drain the socket so a closed page is noticed and the stream dropped.
        drainEventStream(connection)
        if let lastState {
            send(state: lastState, to: connection)
        }
        refresh()
    }

    private func drainEventStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.drainEventStream(connection)
            }
        }
    }

    /// Loads the state off the queue and pushes it to event streams when it changed. Must run on `queue`.
    private func refresh() {
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        DispatchQueue.global().async {
            let state = self.loadState()
            self.queue.async {
                self.isRefreshing = false
                if state != self.lastState {
                    self.lastState = state
                    for connection in self.eventStreams.values {
                        self.send(state: state, to: connection)
                    }
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.refresh()
                }
            }
        }
    }

    private func send(state: Data, to connection: NWConnection) {
        connection.send(content: Data("data: ".utf8) + state + Data("\n\n".utf8), completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private func loadState() -> Data {
        let projects = loadAllRecentProjects(limit: nil).map { project -> [String: Any] in
            var row: [String: Any] = [
                "path": project.path,
                "name": project.displayName.isEmpty ? project.path : project.displayName,
            ]
            if let lastOpenedAt = project.lastOpenedAt {
                row["lastOpenedAt"] = Int(lastOpenedAt.timeIntervalSince1970 * 1000)
            }
            return row
        }
        var state: [String: Any] = ["projects": projects]
        switch loadClaudeSessions() {
        case let .success(sessions):
            state["sessions"] = sessions
        case let .failure(error):
            state["sessions"] = []
            state["error"] = error.message
        }
        return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Active interactive and background sessions from `claude agents --json`. Background sessions get
    /// their claude.ai Remote Control URL from `claude logs`, which prints it once the session connects.
    private func loadClaudeSessions() -> Result<[[String: Any]], CommandError> {
        let result = runClaude(["agents", "--json"])
        guard result.status == EXIT_SUCCESS,
              let sessions = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]]
        else {
            return .failure(CommandError(message: commandFailure("claude agents --json", result)))
        }

        return .success(sessions.map { session in
            var session = session
            if session["kind"] as? String == "background", let id = session["id"] as? String {
                session["remoteURL"] = remoteURL(forSessionID: id, startedAt: session["startedAt"] as? Double)
            }
            return session
        })
    }

    /// Found URLs are cached for good, since `claude logs` only keeps recent output. Misses are
    /// rechecked every refresh while a session is new and still connecting, then every 30 seconds.
    private func remoteURL(forSessionID id: String, startedAt: Double?) -> String? {
        let cached = queue.sync { remoteURLLookups[id] }
        if let url = cached?.url { return url }
        let isNew = startedAt.map { Date().timeIntervalSince1970 * 1000 - $0 < 2 * 60 * 1000 } ?? false
        if let cached, !isNew, Date().timeIntervalSince(cached.checkedAt) < 30 { return nil }

        let result = runClaude(["logs", id])
        let url = result.output.matches(of: /https:\/\/claude\.ai\/code\/session_[A-Za-z0-9]+/).last.map { String($0.output) }
        queue.sync { remoteURLLookups[id] = (url, Date()) }
        return url
    }

    private func respond(on connection: NWConnection, status: String, text: String) {
        respond(on: connection, status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func respond(on connection: NWConnection, status: String, json: [String: Any], headers: [String] = []) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(on: connection, status: status, contentType: "application/json", body: body, headers: headers)
    }

    private func respond(on connection: NWConnection, status: String, contentType: String, body: Data, headers: [String] = []) {
        let extraHeaders = headers.map { "\($0)\r\n" }.joined()
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extraHeaders)\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct CommandError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the head and the full `Content-Length` body have arrived.
    init?(parsing buffer: Data) {
        guard let headEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: headEnd.upperBound, to: buffer.endIndex) >= contentLength else { return nil }

        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")
        self.headers = headers
        body = buffer[headEnd.upperBound..<buffer.index(headEnd.upperBound, offsetBy: contentLength)]
    }
}

/// Loopback, Tailscale's IPv4 range (100.64.0.0/10) and its IPv6 prefix (fd7a:115c:a1e0::/48).
private func isAllowedPeer(_ host: NWEndpoint.Host) -> Bool {
    switch host {
    case let .ipv4(address):
        let bytes = [UInt8](address.rawValue)
        return address.isLoopback || (bytes[0] == 100 && bytes[1] & 0xC0 == 64)
    case let .ipv6(address):
        if address.isLoopback { return true }
        if let mapped = address.asIPv4 { return isAllowedPeer(.ipv4(mapped)) }
        return [UInt8](address.rawValue).prefix(6) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    default:
        return false
    }
}

/// Guards against DNS rebinding: an attacker's page can only reach the server under a name the attacker
/// controls. IP literals, `localhost`, Tailscale MagicDNS names (`*.ts.net`) and single-label MagicDNS
/// short names cannot be such a name.
private func isAllowedHost(_ hostHeader: String) -> Bool {
    let host: Substring
    if hostHeader.hasPrefix("[") {
        guard let end = hostHeader.firstIndex(of: "]") else { return false }
        host = hostHeader[hostHeader.index(after: hostHeader.startIndex)..<end]
        return IPv6Address(String(host)) != nil
    }
    host = hostHeader.split(separator: ":", maxSplits: 1).first ?? ""
    let name = host.lowercased()
    return IPv4Address(name) != nil || name == "localhost" || name.hasSuffix(".ts.net") || (!name.isEmpty && !name.contains("."))
}

/// Reads the web app password, creating a random one on first launch. The file is only readable by the
/// user. The password is 4 groups of 5 characters from a 32-letter alphabet (100 bits), easy to type on a phone.
private func loadOrCreateWebPassword() throws -> String {
    if FileManager.default.fileExists(atPath: webPasswordURL.path) {
        let password = try String(contentsOf: webPasswordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw CommandError(message: "The password file is empty") }
        return password
    }

    // 32 characters, so `byte % 32` is unbiased. Omits i, l and o, which are easy to confuse.
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz0123456789".filter { $0 != "1" })
    var bytes = [UInt8](repeating: 0, count: 20)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw CommandError(message: "Could not generate random bytes")
    }
    let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
    let password = stride(from: 0, to: characters.count, by: 5)
        .map { String(characters[$0..<$0 + 5]) }
        .joined(separator: "-")

    try FileManager.default.createDirectory(at: webPasswordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: webPasswordURL.path, contents: Data("\(password)\n".utf8), attributes: [.posixPermissions: 0o600]) else {
        throw CommandError(message: "Could not create the password file")
    }
    logEvent("web password created path=\(webPasswordURL.path)")
    return password
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhs = Array(lhs.utf8)
    let rhs = Array(rhs.utf8)
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

private func isNewProjectFolder(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return url.deletingLastPathComponent().path == newProjectsRoot.standardizedFileURL.path
        && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Runs `claude` from an interactive login shell so `~/.zshrc` PATH entries and aliases apply, like the
/// Scotty launch. Arguments are passed as positional parameters, so they need no shell quoting.
private func runClaude(_ arguments: [String], directory: String? = nil) -> (output: String, errorOutput: String, status: Int32) {
    runProcessWithStatus(
        executableURL: URL(fileURLWithPath: "/bin/zsh"),
        arguments: ["-ilc", "claude \"$@\"", "zsh"] + arguments,
        currentDirectory: directory
    )
}

private func commandFailure(_ command: String, _ result: (output: String, errorOutput: String, status: Int32)) -> String {
    // Some failures, such as "Workspace not trusted", are printed to stdout.
    let errorOutput = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = errorOutput.isEmpty ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : errorOutput
    return "\(command) failed (exit \(result.status))\(detail.isEmpty ? "" : ": \(detail)")"
}
