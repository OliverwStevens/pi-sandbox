import AppKit
import Foundation
import SwiftUI

enum Health { case ok, warn, bad, unknown }

enum MachineState: Equatable { case unknown, missing, stopped, running }

enum ServerState: Equatable {
    case unknown, down
    case unauthorized
    case ok(models: [String])
}

@MainActor
final class AppState: ObservableObject {
    // MARK: persisted settings
    @Published var serverHost: String { didSet { save(); scheduleProbe() } }
    @Published var serverPort: String { didSet { save(); scheduleProbe() } }
    @Published var apiKey: String { didSet { save(); scheduleProbe() } }
    @Published var model: String { didSet { save() } }
    @Published var projectPath: String { didSet { save() } }

    // MARK: live status
    @Published var podmanPath: String?
    @Published var machine: MachineState = .unknown
    @Published var imageBuilt = false
    @Published var server: ServerState = .unknown
    @Published var runningSandboxes = 0
    @Published var busy: String?
    @Published var showKey = false
    @Published var log = ""

    static let imageName = "pi-sandbox"
    static let containerHost = "host.containers.internal"

    let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PiSandbox", isDirectory: true)
    var agentHome: URL { support.appendingPathComponent("agent-home", isDirectory: true) }
    var buildDir: URL { support.appendingPathComponent("build", isDirectory: true) }
    var keyFile: URL { support.appendingPathComponent("api-key") }

    private var timer: Timer?
    private var probeTask: Task<Void, Never>?

    /// Host without scheme, path or whitespace, so "http://localhost:8001/" pasted by mistake still works.
    var cleanHost: String {
        var h = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where h.lowercased().hasPrefix(prefix) { h = String(h.dropFirst(prefix.count)) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h
    }
    var cleanPort: String { serverPort.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func scheduleProbe() {
        probeTask?.cancel()
        probeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await probeServer()
        }
    }

    init() {
        let d = UserDefaults.standard
        serverHost = d.string(forKey: "serverHost") ?? "localhost"
        serverPort = d.string(forKey: "serverPort") ?? "8001"
        model = d.string(forKey: "model") ?? ""
        projectPath = d.string(forKey: "projectPath") ?? ""
        apiKey = (try? String(contentsOf: support.appendingPathComponent("api-key"), encoding: .utf8)) ?? ""
        installSeed()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.busy == nil else { return }
                await self.refresh()
            }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(serverHost, forKey: "serverHost")
        d.set(serverPort, forKey: "serverPort")
        d.set(model, forKey: "model")
        d.set(projectPath, forKey: "projectPath")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? cleanKey.write(to: keyFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    // MARK: seed files (Dockerfile, AGENTS.md, skills)

    private var seedURL: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("seed"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        return nil
    }

    /// Copies bundled files into Application Support. The Dockerfile is always refreshed;
    /// AGENTS.md and skills are copied only if missing so user edits survive updates.
    func installSeed() {
        let fm = FileManager.default
        guard let seed = seedURL else { return }
        try? fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: agentHome, withIntermediateDirectories: true)
        let dockerfile = buildDir.appendingPathComponent("Dockerfile")
        try? fm.removeItem(at: dockerfile)
        try? fm.copyItem(at: seed.appendingPathComponent("Dockerfile"), to: dockerfile)
        let home = seed.appendingPathComponent("agent-home")
        for item in (try? fm.contentsOfDirectory(atPath: home.path)) ?? [] {
            let dest = agentHome.appendingPathComponent(item)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: home.appendingPathComponent(item), to: dest)
            }
        }
    }

    func resetGuidance() {
        let fm = FileManager.default
        guard let seed = seedURL else { return }
        let home = seed.appendingPathComponent("agent-home")
        for item in ["AGENTS.md", "skills"] {
            let dest = agentHome.appendingPathComponent(item)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: home.appendingPathComponent(item), to: dest)
        }
        append("Reset AGENTS.md and skills to defaults.\n")
    }

    // MARK: logging / helpers

    nonisolated func append(_ s: String) {
        Task { @MainActor in
            self.log += s
            if self.log.count > 40_000 { self.log = String(self.log.suffix(30_000)) }
        }
    }

    private func podman(_ args: [String], stream: Bool = false) async -> ShellResult {
        guard let p = podmanPath else { return ShellResult(code: 127, out: "podman not found") }
        if stream { append("$ podman \(args.joined(separator: " "))\n") }
        if stream {
            return await Shell.run(p, args, onOutput: { [weak self] s in self?.append(s) })
        }
        return await Shell.run(p, args)
    }

    private func withBusy(_ label: String, _ work: () async -> Void) async {
        guard busy == nil else { return }
        busy = label
        await work()
        busy = nil
        await refresh()
    }

    // MARK: status

    func refresh() async {
        podmanPath = Shell.find("podman")
        guard podmanPath != nil else {
            machine = .unknown; imageBuilt = false; runningSandboxes = 0
            await probeServer()
            return
        }
        let list = await podman(["machine", "list", "--format", "json"])
        if let data = list.out.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            if arr.isEmpty { machine = .missing }
            else if arr.contains(where: { ($0["Running"] as? Bool) == true }) { machine = .running }
            else { machine = .stopped }
        } else {
            machine = .unknown
        }
        if machine == .running {
            imageBuilt = (await podman(["image", "exists", Self.imageName])).ok
            let ps = await podman(["ps", "-q", "--filter", "label=pi-sandbox=1"])
            runningSandboxes = ps.out.split(whereSeparator: \.isNewline).count
        } else {
            imageBuilt = false
            runningSandboxes = 0
        }
        await probeServer()
    }

    func probeServer() async {
        guard let url = URL(string: "http://\(cleanHost):\(cleanPort)/v1/models") else { server = .down; return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { server = .unauthorized; return }
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else { server = .down; return }
            let ids = items.compactMap { $0["id"] as? String }
            server = .ok(models: ids)
            if !ids.contains(model), let first = ids.first { model = first }
        } catch {
            server = .down
        }
    }

    var models: [String] {
        if case .ok(let m) = server { return m }
        return []
    }

    // MARK: actions

    func installPodman() async {
        await withBusy("Installing podman…") {
            guard let brew = Shell.find("brew") else {
                append("Homebrew not found. Install podman from https://podman.io/docs/installation\n")
                NSWorkspace.shared.open(URL(string: "https://podman.io/docs/installation")!)
                return
            }
            append("$ brew install podman\n")
            _ = await Shell.run(brew, ["install", "podman"]) { [weak self] s in self?.append(s) }
        }
    }

    func createMachine() async {
        await withBusy("Creating podman machine…") {
            _ = await podman(["machine", "init"], stream: true)
            _ = await podman(["machine", "start"], stream: true)
        }
    }

    func startMachine() async {
        await withBusy("Starting podman machine…") { _ = await podman(["machine", "start"], stream: true) }
    }

    func stopMachine() async {
        await withBusy("Stopping podman machine…") {
            _ = await podman(["machine", "stop"], stream: true)
        }
    }

    func buildImage() async {
        installSeed()
        await withBusy("Building sandbox image…") {
            let r = await podman(["build", "-t", Self.imageName, buildDir.path], stream: true)
            append(r.ok ? "Image built.\n" : "Build failed.\n")
        }
    }

    func stopSandboxes() async {
        await withBusy("Stopping sandboxes…") {
            let ps = await podman(["ps", "-q", "--filter", "label=pi-sandbox=1"])
            let ids = ps.out.split(whereSeparator: \.isNewline).map(String.init)
            if !ids.isEmpty { _ = await podman(["kill"] + ids, stream: true) }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pi can read and change everything in this folder."
        if panel.runModal() == .OK, let url = panel.url { projectPath = url.path }
    }

    func openAgentFolder() {
        installSeed()
        NSWorkspace.shared.open(agentHome)
    }

    var canLaunch: Bool {
        guard busy == nil, podmanPath != nil, !projectPath.isEmpty, !model.isEmpty else { return false }
        if case .ok = server { return true }
        return false
    }

    func launch() async {
        await withBusy("Launching…") {
            guard let podmanPath else { return }
            if machine != .running { _ = await podman(["machine", "start"], stream: true) }
            if !(await podman(["image", "exists", Self.imageName])).ok {
                installSeed()
                let r = await podman(["build", "-t", Self.imageName, buildDir.path], stream: true)
                guard r.ok else { append("Build failed.\n"); return }
            }
            writePiConfig()
            let script = launchScript(podman: podmanPath)
            let file = support.appendingPathComponent("run.command")
            do {
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            } catch {
                append("Could not write launcher: \(error)\n"); return
            }
            NSWorkspace.shared.open(file)
            append("Launched sandbox for \(projectPath)\n")
        }
    }

    // MARK: generated files

    private func containerReachableHost() -> String {
        ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(cleanHost) ? Self.containerHost : cleanHost
    }

    private func writePiConfig() {
        let ids = models.isEmpty ? [model] : models
        let config: [String: Any] = [
            "$schema": "https://pi.dev/schemas/models.schema.json",
            "providers": [
                "omlx": [
                    "baseUrl": "http://\(containerReachableHost()):\(cleanPort)/v1",
                    "api": "openai-completions",
                    "apiKey": "$OMLX_API_KEY",
                    "models": ids.map { ["id": $0] },
                ]
            ],
        ]
        let settings: [String: Any] = [
            "$schema": "https://pi.dev/schemas/settings.schema.json",
            "defaultProvider": "omlx",
            "defaultModel": model,
            "enableInstallTelemetry": false,
        ]
        for (name, obj) in [("models.json", config), ("settings.json", settings)] {
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: agentHome.appendingPathComponent(name))
            }
        }
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func launchScript(podman: String) -> String {
        """
        #!/bin/bash
        # Generated by Pi Sandbox. Do not edit; changes are overwritten on launch.
        export OMLX_API_KEY="$(cat \(q(keyFile.path)))"
        cd \(q(projectPath)) || exit 1
        \(q(podman)) run --rm -it \\
          --label pi-sandbox=1 \\
          --cap-drop=ALL \\
          --security-opt=no-new-privileges \\
          --read-only \\
          --tmpfs /tmp:rw,size=256m \\
          --tmpfs /root:rw,size=128m \\
          --pids-limit=256 --memory=1g --cpus=2 \\
          -e OMLX_API_KEY \\
          -v \(q(projectPath)):/workspace \\
          -v \(q(agentHome.path)):/seed:ro \\
          --entrypoint bash \(Self.imageName) -c 'mkdir -p /root/.pi && cp -r /seed /root/.pi/agent && exec pi'
        echo
        echo "Sandbox exited. You can close this window."
        """
    }
}
