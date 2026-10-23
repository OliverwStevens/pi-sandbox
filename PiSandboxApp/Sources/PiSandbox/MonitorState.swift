import Foundation
import SwiftUI

struct NetObservation: Identifiable {
    var id: String { connection.id }
    let connection: Connection
    let first: Date
    let expected: Bool
}

@MainActor
final class MonitorState: ObservableObject {
    @Published var stats = SessionStats()
    @Published var findings: [Finding] = []
    @Published var score = 0
    @Published var level = "Low"
    @Published var verdict = "No session analysed yet."
    @Published var cpu = "–"
    @Published var memory = "–"
    @Published var network: [NetObservation] = []
    @Published var filesChanged = 0
    @Published var sessionFile = ""
    @Published var lastUpdate: Date?

    private var baseline: [String: FileEntry]?
    private var baselineRoot = ""
    private var gatewayIPs: Set<String> = []
    private var seen: [String: NetObservation] = [:]
    private var refreshing = false

    /// Take the "before" picture of the project folder. Called when a sandbox launches.
    func startBaseline(project: String) {
        baselineRoot = project
        seen = [:]
        gatewayIPs = []
        network = []
        Task {
            let snap = await Task.detached { FileWatcher.snapshot(root: project) }.value
            baseline = snap
        }
    }

    func refresh(podman: String?, connection: String, project: String, sessions: URL, running: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        // 1. newest pi session log
        let newest = await Task.detached { Self.newestSession(in: sessions) }.value
        var all: [Finding] = []
        if let newest {
            let result = await Task.detached { RiskEngine.analyzeSession(at: newest) }.value
            var s = result.0
            if !running && s.steps > 0 { s.status = "Session ended" }
            stats = s
            all += result.1
            sessionFile = newest.lastPathComponent
        }

        // 2. files changed on the Mac side
        if let base = baseline, !project.isEmpty, project == baselineRoot {
            let root = project
            let (found, changed) = await Task.detached { () -> ([Finding], Int) in
                let now = FileWatcher.snapshot(root: root)
                let d = FileWatcher.diff(base: base, now: now)
                return (d.findings, d.changed)
            }.value
            all += found
            filesChanged = changed
        }

        // 3. live container: resources + network
        if running, let podmanBin = podman {
            let podman = { (args: [String]) in await Shell.run(podmanBin, ["--connection", connection] + args) }
            let ps = await podman(["ps", "-q", "--filter", "label=pi-sandbox=1"])
            let ids = ps.out.split(whereSeparator: \.isNewline).map(String.init)
            if let id = ids.first {
                let st = await podman(["stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", id])
                let parts = st.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
                if parts.count == 2 { cpu = String(parts[0]); memory = String(parts[1]) }

                if gatewayIPs.isEmpty {
                    for name in ["pi-gate", "host.containers.internal"] {
                        let g = await podman(["exec", id, "getent", "hosts", name])
                        if let first = g.out.split(separator: " ").first { gatewayIPs.insert(String(first)) }
                    }
                }
                let net = await podman(["exec", id, "cat", "/proc/net/tcp", "/proc/net/tcp6"])
                for c in NetParse.remotes(net.out) where !c.ip.hasPrefix("127.") && c.ip != "0.0.0.0" {
                    if seen[c.id] == nil {
                        seen[c.id] = NetObservation(connection: c, first: Date(), expected: gatewayIPs.contains(c.ip))
                    }
                }
                network = seen.values.sorted { $0.first > $1.first }
            }
        } else if !running {
            cpu = "–"; memory = "–"
        }
        for o in seen.values where !o.expected {
            all.append(Finding(time: o.first, severity: .high, category: "Outbound connection that is not the model server",
                               detail: "\(o.connection.ip):\(o.connection.port)", source: "network"))
        }

        all.sort { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
        findings = all
        score = RiskEngine.score(all, looping: stats.looping)
        let lv = RiskEngine.level(score)
        level = lv.0
        verdict = lv.1
        lastUpdate = Date()
    }

    nonisolated static func newestSession(in dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (URL, Date)?
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || d > best!.1 { best = (url, d) }
        }
        return best?.0
    }
}
