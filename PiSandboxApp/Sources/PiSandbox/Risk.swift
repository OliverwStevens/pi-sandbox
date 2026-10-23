import Foundation

enum Severity: Int, Comparable {
    case low = 1, medium, high, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Critical"
        }
    }
    var weight: Double {
        switch self {
        case .low: 1
        case .medium: 4
        case .high: 14
        case .critical: 35
        }
    }
}

struct Finding: Identifiable {
    let id = UUID()
    var time: Date?
    var severity: Severity
    var category: String
    var detail: String
    var source: String       // "command", "file", "network"
    var blocked = false      // the sandbox stopped it
}

struct SessionStats {
    var model = ""
    var prompts = 0
    var steps = 0
    var toolCalls: [String: Int] = [:]
    var tokens = 0
    var errors = 0
    var started: Date?
    var last: Date?
    var looping = false
    var loopDetail = ""
    var status = "No session yet"
    var phase = "–"
    var filesTouched = 0
}

enum RiskEngine {
    // MARK: command rules (matched against the lowercased shell command)

    struct Rule {
        let pattern: String
        let severity: Severity
        let category: String
    }

    static let commandRules: [Rule] = [
        Rule(pattern: #"(curl|wget)[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, severity: .critical, category: "Pipes a download into a shell"),
        Rule(pattern: #"base64\s+(-d|--decode)[^|]*\|\s*(ba|z)?sh\b"#, severity: .critical, category: "Decodes and runs hidden code"),
        Rule(pattern: #"/dev/tcp/|/dev/udp/"#, severity: .critical, category: "Possible reverse shell"),
        Rule(pattern: #"docker\.sock|podman\.sock"#, severity: .critical, category: "Targets the container engine socket"),
        Rule(pattern: #"\b(nsenter|chroot|unshare|capsh|setcap|insmod|modprobe|debugfs)\b"#, severity: .critical, category: "Container-escape style tooling"),
        Rule(pattern: #"rm\s+-[a-z]*r[a-z]*\s+(-[a-z]+\s+)*(/|~|\$home|\*|\.|/workspace/?)(\s|$)"#, severity: .critical, category: "Mass deletion"),
        Rule(pattern: #"(^|[;&|]\s*)(sudo|su|doas)\s"#, severity: .high, category: "Privilege escalation attempt"),
        Rule(pattern: #"(^|[;&|]\s*)mount\s"#, severity: .high, category: "Tries to mount a filesystem"),
        Rule(pattern: #"/proc/(self|\d+)/(environ|mem|maps)"#, severity: .high, category: "Reads process memory or environment"),
        Rule(pattern: #"\.ssh|id_rsa|id_ed25519|\.aws/|\.netrc|\.gnupg|\.config/gh|keychain|\.npmrc|\.pypirc|\.docker/config|credentials"#, severity: .high, category: "Touches credential files"),
        Rule(pattern: #"\bgit\s+push\b|\bgh\s+(pr|repo|auth|api|release|gist|secret)\b"#, severity: .high, category: "GitHub / push activity"),
        Rule(pattern: #"\bgit\s+remote\s+(add|set-url)\b"#, severity: .high, category: "Changes git remotes"),
        Rule(pattern: #"\b(curl|wget)\b.*(\s-d\s|--data|-T\s|--upload-file|\s-f\s|--form|-x\s*(post|put)|--request\s+(post|put))"#, severity: .high, category: "Uploads data to a server"),
        Rule(pattern: #"(^|[;&|(]\s*)(ssh|scp|sftp|rsync)\s"#, severity: .high, category: "Remote access or transfer"),
        Rule(pattern: #"(touch|tee|cp|mv|ln|mkdir|chmod|chown|>>?)\s*/(usr|etc|bin|sbin|lib|var|opt|root|sys|proc)\b"#, severity: .high, category: "Tries to modify system files"),
        Rule(pattern: #"(^|[;&|(]\s*)(nc|ncat|netcat|socat)\s"#, severity: .high, category: "Raw network tool"),
        Rule(pattern: #"\.git/hooks|\.github/workflows|\.envrc|\.bashrc|\.zshrc|\.zprofile|\.profile|crontab|launchagents|launchd"#, severity: .high, category: "Touches a file your Mac will execute"),
        Rule(pattern: #"\b(printenv)\b|(^|[;&|]\s*)env\s*($|[|>])"#, severity: .medium, category: "Dumps environment variables"),
        Rule(pattern: #"\b(pip3?|npm|pnpm|yarn|gem|bundle|cargo|go|apt-get|apt|apk|brew)\s+(install|add|get)\b"#, severity: .medium, category: "Installs packages (supply chain)"),
        Rule(pattern: #"\bgit\s+clone\b"#, severity: .medium, category: "Clones a repository"),
        Rule(pattern: #"\b(curl|wget)\b"#, severity: .medium, category: "Fetches from the network"),
        Rule(pattern: #"rm\s+-[a-z]*r"#, severity: .medium, category: "Recursive delete"),
        Rule(pattern: #"\bchmod\s+(-r\s+)?(\+x|[0-7]*7[0-7]*)"#, severity: .medium, category: "Changes file permissions"),
        Rule(pattern: #"(^|[;&|]\s*)(find|ls|cat|tree|du)\s[^;&|]*\s/(users|etc|root|home|var|private|volumes)\b"#, severity: .medium, category: "Explores outside the project"),
        Rule(pattern: #"\b(eval|python3?\s+-c|node\s+-e|perl\s+-e|ruby\s+-e)\b"#, severity: .low, category: "Runs inline code"),
    ]

    /// Files that run on your Mac (not in the container) when you commit, build or open a shell.
    static func hostExecutedSeverity(path: String) -> (Severity, String)? {
        let p = path.lowercased()
        if p.contains(".git/hooks/") { return (.critical, "Git hook (runs on your Mac at your next commit)") }
        if p.hasSuffix(".git/config") { return (.high, "Git config (can add hooks, remotes, credential helpers)") }
        if p.contains(".github/workflows/") { return (.high, "CI workflow (runs with your repo's secrets)") }
        let name = (p as NSString).lastPathComponent
        if [".envrc", ".bashrc", ".zshrc", ".zprofile", ".profile", ".gitattributes"].contains(name) { return (.high, "Shell or environment startup file") }
        if name.hasPrefix(".env") { return (.high, "Environment/secrets file") }
        if ["makefile", "rakefile", "justfile", "package.json", "dockerfile", "docker-compose.yml", ".pre-commit-config.yaml", "tasks.json", "gemfile", "setup.py", "pyproject.toml"].contains(name) { return (.medium, "Build file (runs if you build or install)") }
        if name.hasSuffix(".sh") || name.hasSuffix(".command") || name.hasSuffix(".pkg") { return (.medium, "Script (runs if you execute it)") }
        return nil
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let p = path.lowercased()
        let hints = [".ssh", "id_rsa", "id_ed25519", ".aws", ".netrc", ".gnupg", ".config/gh", ".npmrc", ".pypirc", "credentials", ".pem", ".key", "secrets"]
        return hints.contains { p.contains($0) }
    }

    static let blockedMarkers = [
        "read-only file system", "operation not permitted", "permission denied",
        "cannot open", "no such file or directory", "not found",
    ]

    // MARK: session analysis

    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func stringArgs(_ args: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in args { if let s = v as? String { out[k] = s } }
        return out
    }

    static func analyzeSession(at url: URL) -> (SessionStats, [Finding]) {
        var stats = SessionStats()
        var findings: [Finding] = []
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (stats, findings) }

        var pendingFinding: [String: Int] = [:]   // toolCallId -> index in findings
        var signatures: [String] = []
        var recentTools: [String] = []
        var written = Set<String>()
        var lastRole = "", lastStop = "", lastTool = ""

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let when = isoDate(obj["timestamp"] as? String)
            if let w = when {
                if stats.started == nil { stats.started = w }
                stats.last = w
            }
            if type == "model_change", let m = obj["modelId"] as? String { stats.model = m }
            guard type == "message", let msg = obj["message"] as? [String: Any],
                  let role = msg["role"] as? String else { continue }
            if role == "system" { continue }
            lastRole = role

            if role == "user" { stats.prompts += 1 }

            if role == "assistant" {
                stats.steps += 1
                lastStop = (msg["stopReason"] as? String) ?? ""
                if let usage = msg["usage"] as? [String: Any] {
                    stats.tokens += (usage["input"] as? Int ?? 0) + (usage["output"] as? Int ?? 0)
                }
                for item in (msg["content"] as? [[String: Any]]) ?? [] where (item["type"] as? String) == "toolCall" {
                    let name = (item["name"] as? String) ?? "tool"
                    let args = (item["arguments"] as? [String: Any]) ?? [:]
                    let callId = (item["id"] as? String) ?? UUID().uuidString
                    stats.toolCalls[name, default: 0] += 1
                    lastTool = name
                    recentTools.append(name)
                    let strs = stringArgs(args)
                    let sig = name + "|" + (strs["command"] ?? strs.values.sorted().joined(separator: ","))
                    signatures.append(sig)

                    let new = assess(tool: name, args: strs, time: when)
                    for p in strs where ["path", "file_path", "filepath", "file"].contains(p.key) && ["write", "edit"].contains(name) { written.insert(p.value) }
                    if !new.isEmpty {
                        findings.append(contentsOf: new)
                        pendingFinding[callId] = findings.count - new.count
                    }
                }
            }

            if role == "toolResult" {
                let isError = (msg["isError"] as? Bool) ?? false
                if isError { stats.errors += 1 }
                let body = ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined().lowercased()
                if let id = msg["toolCallId"] as? String, let start = pendingFinding[id] {
                    let denied = isError || body.contains("read-only file system") || body.contains("operation not permitted") || body.contains("permission denied")
                    if denied && blockedMarkers.contains(where: { body.contains($0) }) {
                        // mark all findings produced by that call as blocked
                        var i = start
                        while i < findings.count, findings[i].time == findings[start].time, findings[i].source == "command" || findings[i].source == "file-tool" {
                            findings[i].blocked = true
                            i += 1
                        }
                    }
                }
            }
        }

        stats.filesTouched = written.count

        // loop detection: same call 3+ times within the last 12 calls
        let window = signatures.suffix(12)
        let counts = Dictionary(window.map { ($0, 1) }, uniquingKeysWith: +)
        if let worst = counts.max(by: { $0.value < $1.value }), worst.value >= 3 {
            stats.looping = true
            stats.loopDetail = String(worst.key.prefix(80))
        }

        // phase from the recent tool mix
        let recent = recentTools.suffix(8)
        if !recent.isEmpty {
            let writes = recent.filter { $0 == "edit" || $0 == "write" }.count
            let reads = recent.filter { $0 == "read" }.count
            let bash = recent.filter { $0 == "bash" }.count
            if stats.looping { stats.phase = "Stuck" }
            else if writes >= max(reads, 2) { stats.phase = "Implementing" }
            else if reads > bash && reads >= writes { stats.phase = "Exploring" }
            else if bash >= 2 { stats.phase = "Running / verifying" }
            else { stats.phase = "Working" }
        }

        if stats.steps == 0 { stats.status = "No session yet" }
        else if stats.looping { stats.status = "Possibly stuck: repeating the same call" }
        else if lastRole == "assistant" && lastStop == "stop" { stats.status = "Waiting for you" }
        else if lastRole == "assistant" { stats.status = "Working (\(lastTool))" }
        else { stats.status = "Thinking" }

        return (stats, findings)
    }

    static func assess(tool: String, args: [String: String], time: Date?) -> [Finding] {
        var out: [Finding] = []
        func add(_ s: Severity, _ c: String, _ d: String, _ src: String) {
            out.append(Finding(time: time, severity: s, category: c, detail: String(d.prefix(160)), source: src))
        }
        if tool == "bash", let cmd = args["command"] {
            let lower = cmd.lowercased()
            var seen = Set<String>()
            for r in commandRules where lower.range(of: r.pattern, options: .regularExpression) != nil {
                if seen.insert(r.category).inserted { add(r.severity, r.category, cmd, "command") }
            }
            // keep only the top three distinct reasons per command to avoid noise
            out.sort { $0.severity > $1.severity }
            // a serious reason makes the weaker ones on the same command redundant
            if let top = out.first?.severity, top >= .high { out = out.filter { $0.severity >= .high } }
            if out.count > 3 { out = Array(out.prefix(3)) }
            return out
        }
        let path = args["path"] ?? args["file_path"] ?? args["filepath"] ?? args["file"] ?? ""
        guard !path.isEmpty else { return out }
        let inside = path.hasPrefix("/workspace") || (!path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains(".."))
        let docs = path.hasPrefix("/usr/local/lib/node_modules")
        if tool == "write" || tool == "edit" {
            if !inside { add(.high, "Writes outside the project", path, "file-tool") }
            if let (sev, why) = hostExecutedSeverity(path: path) { add(sev, "Edits a host-executed file: \(why)", path, "file-tool") }
            if isSensitivePath(path) { add(.high, "Writes to a credential-like path", path, "file-tool") }
        } else if tool == "read" {
            if isSensitivePath(path) { add(.high, "Reads a credential-like path", path, "file-tool") }
            else if !inside && !docs { add(.medium, "Reads outside the project", path, "file-tool") }
        }
        return out
    }

    // MARK: score

    static func score(_ findings: [Finding], looping: Bool) -> Int {
        var total = 0.0
        for f in findings { total += f.severity.weight * (f.blocked ? 0.25 : 1) }
        if looping { total += 5 }
        return Int(min(100, total.rounded()))
    }

    static func level(_ score: Int) -> (String, String) {
        switch score {
        case ..<10: ("Low", "Behaving like a normal coding session.")
        case ..<35: ("Elevated", "A few things worth a look. Review the findings below.")
        case ..<70: ("High", "Risky actions detected. Review before running anything pi produced.")
        default: ("Critical", "Stop the session and inspect the project before using it.")
        }
    }
}

// MARK: - host-side file watcher

struct FileEntry: Equatable {
    var mtime: TimeInterval
    var size: Int
    var mode: Int
    var linkTarget: String?
}

enum FileWatcher {
    static let skipDirs: Set<String> = ["node_modules", ".build", "target", "vendor", ".next", "dist", "Pods", ".venv", "__pycache__", ".gradle", "DerivedData"]

    static func snapshot(root: String, limit: Int = 30_000) -> [String: FileEntry] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: root)
        var out: [String: FileEntry] = [:]
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                     options: [], errorHandler: { _, _ in true }) else { return out }
        for case let url as URL in en {
            if out.count >= limit { break }
            let rel = String(url.path.dropFirst(base.path.count + 1))
            let comps = rel.split(separator: "/").map(String.init)
            let name = comps.last ?? ""
            if skipDirs.contains(name) { en.skipDescendants(); continue }
            if comps.first == ".git" {
                // inside .git only hooks/ and config matter
                let keep = comps.count == 1 || comps[1] == "hooks" || (comps.count == 2 && comps[1] == "config")
                if !keep { en.skipDescendants(); continue }
            }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if (attrs[.type] as? FileAttributeType) == .typeDirectory { continue }
            let link = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
                ? (try? fm.destinationOfSymbolicLink(atPath: url.path)) : nil
            out[rel] = FileEntry(
                mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                size: (attrs[.size] as? Int) ?? 0,
                mode: (attrs[.posixPermissions] as? Int) ?? 0,
                linkTarget: link)
        }
        return out
    }

    static func diff(base: [String: FileEntry], now: [String: FileEntry]) -> (findings: [Finding], changed: Int) {
        var findings: [Finding] = []
        var changed = 0
        for (path, e) in now {
            let old = base[path]
            if old == e { continue }
            changed += 1
            let time = Date(timeIntervalSince1970: e.mtime)
            if let target = e.linkTarget, old?.linkTarget != target {
                let escapes = target.hasPrefix("/") || target.hasPrefix("~") || target.contains("..")
                if escapes {
                    findings.append(Finding(time: time, severity: .high, category: "Symlink pointing outside the project", detail: "\(path) -> \(target)", source: "file"))
                }
            }
            if let (sev, why) = RiskEngine.hostExecutedSeverity(path: path) {
                findings.append(Finding(time: time, severity: sev, category: old == nil ? "New host-executed file: \(why)" : "Changed host-executed file: \(why)", detail: path, source: "file"))
            }
            if let old, old.mode & 0o111 == 0, e.mode & 0o111 != 0 {
                findings.append(Finding(time: time, severity: .medium, category: "File made executable", detail: path, source: "file"))
            }
        }
        let deleted = base.keys.filter { now[$0] == nil }.count
        if deleted >= 20 {
            findings.append(Finding(time: Date(), severity: .high, category: "Mass deletion", detail: "\(deleted) files removed from the project", source: "file"))
        }
        return (findings, changed + deleted)
    }
}

// MARK: - network parsing

struct Connection: Identifiable, Hashable {
    var id: String { "\(ip):\(port)" }
    let ip: String
    let port: Int
}

enum NetParse {
    /// Parses /proc/net/tcp and tcp6 content into remote endpoints (established or connecting).
    static func remotes(_ proc: String) -> [Connection] {
        var out: [Connection] = []
        for line in proc.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count > 3, cols[0].hasSuffix(":"), cols[3] == "01" || cols[3] == "02" else { continue }
            let rem = cols[2].split(separator: ":")
            guard rem.count == 2, let port = Int(rem[1], radix: 16) else { continue }
            let hex = String(rem[0])
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
                idx = next
            }
            var ip = ""
            if bytes.count == 4 {
                ip = bytes.reversed().map(String.init).joined(separator: ".")
            } else if bytes.count == 16 {
                // each 4-byte word is little-endian; IPv4-mapped addresses end with the v4 word
                let words = stride(from: 0, to: 16, by: 4).map { Array(bytes[$0..<$0 + 4].reversed()) }
                if words[0] == [0, 0, 0, 0], words[1] == [0, 0, 0, 0], words[2] == [0, 0, 0xff, 0xff] {
                    ip = words[3].map(String.init).joined(separator: ".")
                } else {
                    ip = words.map { $0.map { String(format: "%02x", $0) }.joined() }.joined(separator: ":")
                }
            }
            if !ip.isEmpty { out.append(Connection(ip: ip, port: port)) }
        }
        return out
    }
}
