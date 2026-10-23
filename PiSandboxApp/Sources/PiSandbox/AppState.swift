import AppKit
import Foundation
import SwiftUI

enum Health { case ok, warn, bad, unknown }

struct TestResult: Identifiable {
    let id = UUID()
    let status: String   // PASS, FAIL or WARN
    let text: String
}

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
    @Published var allowInternet: Bool { didSet { save() } }

    // MARK: live status
    @Published var podmanPath: String?
    @Published var machine: MachineState = .unknown
    @Published var otherMachineRunning: String?
    @Published var imageBuilt = false
    @Published var server: ServerState = .unknown
    @Published var runningSandboxes = 0
    @Published var busy: String?
    @Published var showKey = false
    @Published var showLog = false
    @Published var tab = 0
    @Published var selfTest: [TestResult] = []
    @Published var selfTestRan = false
    @Published var log = ""

    static let imageName = "pi-sandbox"
    static let machineName = "pi-sandbox"
    static let netName = "pi-sandbox-net"
    static let gateName = "pi-gate"
    static let containerHost = "host.containers.internal"

    let support: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PiSandbox", isDirectory: true)

    /// The only host folder the Podman VM can see. Projects must live inside it.
    let workspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("PiSandbox", isDirectory: true)
    var runtimeDir: URL { workspaceRoot.appendingPathComponent(".runtime", isDirectory: true) }
    var agentHome: URL { runtimeDir.appendingPathComponent("agent-home", isDirectory: true) }
    var sessionsDir: URL { runtimeDir.appendingPathComponent("sessions", isDirectory: true) }
    var selfTestProject: URL { runtimeDir.appendingPathComponent("selftest-project", isDirectory: true) }
    var selfTestScript: URL { runtimeDir.appendingPathComponent("sandbox-selftest.sh") }
    var buildDir: URL { support.appendingPathComponent("build", isDirectory: true) }
    var keyFile: URL { support.appendingPathComponent("api-key") }
    let monitor = MonitorState()

    private var timer: Timer?
    private var monitorTimer: Timer?
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
        allowInternet = d.bool(forKey: "allowInternet")
        apiKey = (try? String(contentsOf: support.appendingPathComponent("api-key"), encoding: .utf8)) ?? ""
        installSeed()
        Task { await refresh() }
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.monitor.refresh(podman: self.podmanPath, connection: Self.machineName, project: self.projectPath,
                                           sessions: self.sessionsDir, running: self.runningSandboxes > 0)
            }
        }
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
        d.set(allowInternet, forKey: "allowInternet")
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

    /// Copies bundled files into place. Build files and the self-test are always refreshed;
    /// AGENTS.md and skills are copied only if missing so user edits survive updates.
    func installSeed() {
        let fm = FileManager.default
        guard let seed = seedURL else { return }
        for dir in [buildDir, agentHome, sessionsDir] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for name in ["Dockerfile", "gate-forward.js"] {
            let dest = buildDir.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: seed.appendingPathComponent(name), to: dest)
        }
        try? fm.removeItem(at: selfTestScript)
        try? fm.copyItem(at: seed.appendingPathComponent("sandbox-selftest.sh"), to: selfTestScript)
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

    /// Runs podman against the dedicated machine. `machine` subcommands are passed through untouched.
    private func podman(_ args: [String], stream: Bool = false) async -> ShellResult {
        guard let p = podmanPath else { return ShellResult(code: 127, out: "podman not found") }
        let full = args.first == "machine" ? args : ["--connection", Self.machineName] + args
        if stream {
            append("$ podman \(full.joined(separator: " "))\n")
            return await Shell.run(p, full, onOutput: { [weak self] s in self?.append(s) })
        }
        return await Shell.run(p, full)
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
        otherMachineRunning = nil
        if let data = list.out.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let name: ([String: Any]) -> String = { ($0["Name"] as? String ?? "").replacingOccurrences(of: "*", with: "") }
            if let mine = arr.first(where: { name($0) == Self.machineName }) {
                machine = (mine["Running"] as? Bool) == true ? .running : .stopped
            } else {
                machine = .missing
            }
            otherMachineRunning = arr.first(where: { name($0) != Self.machineName && ($0["Running"] as? Bool) == true }).map(name)
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

    // MARK: machine + image actions

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

    /// Podman on macOS runs one VM at a time, so any other running machine is stopped first.
    private func stopOtherMachines() async {
        if let other = otherMachineRunning {
            append("Stopping Podman machine '\(other)' (only one VM can run at a time).\n")
            _ = await podman(["machine", "stop", other], stream: true)
        }
    }

    func createMachine() async {
        await withBusy("Creating the sandbox VM…") {
            try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
            await stopOtherMachines()
            let root = workspaceRoot.path
            _ = await podman(["machine", "init", Self.machineName, "--cpus", "4", "--memory", "2048",
                              "--disk-size", "20", "-v", "\(root):\(root)"], stream: true)
            _ = await podman(["machine", "start", Self.machineName], stream: true)
        }
    }

    func startMachine() async {
        await withBusy("Starting the sandbox VM…") {
            await stopOtherMachines()
            _ = await podman(["machine", "start", Self.machineName], stream: true)
        }
    }

    func stopMachine() async {
        await withBusy("Stopping the sandbox VM…") {
            _ = await podman(["machine", "stop", Self.machineName], stream: true)
        }
    }

    private func ensureMachineRunning() async -> Bool {
        if machine == .missing { append("Create the sandbox VM first.\n"); return false }
        if machine != .running {
            await stopOtherMachines()
            _ = await podman(["machine", "start", Self.machineName], stream: true)
        }
        return true
    }

    private func ensureImage() async -> Bool {
        if (await podman(["image", "exists", Self.imageName])).ok { return true }
        installSeed()
        let r = await podman(["build", "-t", Self.imageName, buildDir.path], stream: true)
        if !r.ok { append("Build failed.\n") }
        return r.ok
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
            _ = await podman(["rm", "-f", Self.gateName])
        }
    }

    // MARK: network lock

    /// Internal network with no route out, plus one forwarder container that relays only the model server's port.
    private func ensureGate() async -> Bool {
        if !(await podman(["network", "exists", Self.netName])).ok {
            let r = await podman(["network", "create", "--internal", Self.netName], stream: true)
            if !r.ok { return false }
        }
        let target = "\(containerReachableHost()):\(cleanPort)"
        let label = await podman(["inspect", "--format", "{{index .Config.Labels \"pi-gate-target\"}}", Self.gateName])
        if label.ok && label.out.trimmingCharacters(in: .whitespacesAndNewlines) == target {
            let up = await podman(["ps", "-q", "--filter", "name=^\(Self.gateName)$"])
            if !up.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        _ = await podman(["rm", "-f", Self.gateName])
        let r = await podman([
            "run", "-d", "--name", Self.gateName, "--label", "pi-gate=1", "--label", "pi-gate-target=\(target)",
            "--network", Self.netName, "--network", "podman",
            "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only",
            "--memory=128m", "--pids-limit=64", "--restart=no",
            "--entrypoint", "node", Self.imageName, "/opt/gate-forward.js", cleanPort, containerReachableHost(), cleanPort,
        ], stream: true)
        if !r.ok { append("Could not start the network gate.\n") }
        return r.ok
    }

    // MARK: protections

    /// Paths inside the project that your Mac executes later (git hooks, CI, shell env). Mounted read-only in the sandbox.
    static let protectedPaths = [
        ".git/hooks", ".git/config", ".gitmodules", ".gitattributes", ".github", ".envrc",
        ".vscode", ".husky", ".pre-commit-config.yaml", ".devcontainer",
    ]

    func protectedMounts(project: String) -> [String] {
        var out: [String] = []
        for rel in Self.protectedPaths where FileManager.default.fileExists(atPath: project + "/" + rel) {
            out += ["-v", "\(project)/\(rel):/workspace/\(rel):ro"]
        }
        return out
    }

    /// Flags that define the sandbox. Shared by the launcher and the self-test so the test checks what really runs.
    static let hardening = [
        "--cap-drop=ALL", "--security-opt=no-new-privileges", "--read-only",
        "--tmpfs", "/tmp:rw,size=256m", "--tmpfs", "/root:rw,size=128m",
        "--pids-limit=256", "--memory=1g", "--cpus=2",
    ]

    /// Fixed git identity so commits work without any host config.
    static let gitEnv = [
        "-e", "GIT_AUTHOR_NAME=pi", "-e", "GIT_AUTHOR_EMAIL=pi@sandbox.invalid",
        "-e", "GIT_COMMITTER_NAME=pi", "-e", "GIT_COMMITTER_EMAIL=pi@sandbox.invalid",
    ]

    var networkArgs: [String] { allowInternet ? [] : ["--network", Self.netName] }

    // MARK: workspace

    var projectInsideWorkspace: Bool {
        !projectPath.isEmpty && projectPath.hasPrefix(workspaceRoot.path + "/")
    }

    func revealWorkspace() {
        try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(workspaceRoot)
    }

    func chooseProject() {
        try? FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = workspaceRoot
        panel.prompt = "Choose"
        panel.message = "Pi can read and change everything in this folder. It must be inside ~/PiSandbox."
        guard panel.runModal() == .OK, let picked = panel.url?.resolvingSymlinksInPath() else { return }
        let root = workspaceRoot.resolvingSymlinksInPath().path
        if picked.path.hasPrefix(root + "/") { projectPath = picked.path; return }

        let alert = NSAlert()
        alert.messageText = "Copy “\(picked.lastPathComponent)” into ~/PiSandbox?"
        alert.informativeText = "The sandbox VM can only see ~/PiSandbox, so the rest of your Mac stays out of reach. Pi will work on the copy; bring changes back with git or by copying files."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let dest = workspaceRoot.appendingPathComponent(picked.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            append("\(dest.path) already exists; using it.\n")
            projectPath = dest.path
            return
        }
        Task {
            busy = "Copying project…"
            let r = await Shell.run("/usr/bin/ditto", [picked.path, dest.path])
            append(r.ok ? "Copied to \(dest.path)\n" : "Copy failed: \(r.out)\n")
            if r.ok { projectPath = dest.path }
            busy = nil
        }
    }

    func openAgentFolder() {
        installSeed()
        NSWorkspace.shared.open(agentHome)
    }

    var isReady: Bool {
        guard podmanPath != nil, machine == .running, projectInsideWorkspace else { return false }
        if case .ok = server { return true }
        return false
    }

    var canLaunch: Bool {
        guard busy == nil, podmanPath != nil, projectInsideWorkspace, !model.isEmpty, machine != .missing else { return false }
        if case .ok = server { return true }
        return false
    }

    // MARK: self-test

    func runSelfTest() async {
        await withBusy("Running sandbox self-test…") {
            guard await ensureMachineRunning(), await ensureImage() else { return }
            installSeed()
            if !allowInternet { guard await ensureGate() else { return } }

            let fm = FileManager.default
            let canary = support.appendingPathComponent("sandbox-canary-\(UUID().uuidString).txt")
            try? "host secret".write(to: canary, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: canary) }
            let project = selfTestProject
            for rel in [".git/hooks", ".github"] { try? fm.createDirectory(at: project.appendingPathComponent(rel), withIntermediateDirectories: true) }
            try? "[core]\n".write(to: project.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

            var results: [TestResult] = []
            // App-side: what can the VM itself see of your home folder?
            let ls = await Shell.run(podmanPath ?? "", ["machine", "ssh", Self.machineName, "ls -A \(NSHomeDirectory())"])
            let seen = ls.out.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(seen == "PiSandbox"
                ? TestResult(status: "PASS", text: "The sandbox VM sees only ~/PiSandbox, not the rest of your home folder")
                : TestResult(status: "FAIL", text: "The sandbox VM can see more than ~/PiSandbox: \(seen.replacingOccurrences(of: "\n", with: ", "))"))

            let args = ["run", "--rm"] + Self.hardening + networkArgs + protectedMounts(project: project.path) + [
                "-e", "CANARY=\(canary.path)", "-e", "HOST_PORT=\(cleanPort)",
                "-e", "NET_MODE=\(allowInternet ? "open" : "locked")", "-e", "GATE=\(Self.gateName)",
                "-v", "\(project.path):/workspace", "-v", "\(selfTestScript.path):/selftest.sh:ro",
                "--entrypoint", "bash", Self.imageName, "/selftest.sh",
            ]
            let r = await podman(args)
            for line in r.out.split(whereSeparator: \.isNewline) {
                for tag in ["PASS", "FAIL", "WARN"] where line.hasPrefix(tag + " ") {
                    results.append(TestResult(status: tag, text: String(line.dropFirst(5))))
                }
            }
            if results.count <= 1 { append("Self-test produced no container results:\n\(r.out)\n") }
            selfTest = results
            selfTestRan = true
        }
    }

    // MARK: launch

    func launch() async {
        await withBusy("Launching…") {
            guard let podmanPath else { return }
            guard await ensureMachineRunning(), await ensureImage() else { return }
            if !allowInternet { guard await ensureGate() else { return } }
            writePiConfig()
            let script = launchScript(podman: podmanPath)
            let file = support.appendingPathComponent("run.command")
            do {
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            } catch {
                append("Could not write launcher: \(error)\n"); return
            }
            monitor.startBaseline(project: projectPath)
            NSWorkspace.shared.open(file)
            tab = 1
            append("Launched sandbox for \(projectPath)\n")
        }
    }

    // MARK: generated files

    private func containerReachableHost() -> String {
        ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(cleanHost) ? Self.containerHost : cleanHost
    }

    private func writePiConfig() {
        let ids = models.isEmpty ? [model] : models
        let upstream = allowInternet ? containerReachableHost() : Self.gateName
        let config: [String: Any] = [
            "$schema": "https://pi.dev/schemas/models.schema.json",
            "providers": [
                "omlx": [
                    "baseUrl": "http://\(upstream):\(cleanPort)/v1",
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
        let flags = (Self.hardening + networkArgs + Self.gitEnv + protectedMounts(project: projectPath))
            .map(q).joined(separator: " ")
        return """
        #!/bin/bash
        # Generated by Pi Sandbox. Do not edit; changes are overwritten on launch.
        export OMLX_API_KEY="$(cat \(q(keyFile.path)))"
        cd \(q(projectPath)) || exit 1
        \(q(podman)) --connection \(Self.machineName) run --rm -it \\
          --label pi-sandbox=1 \\
          \(flags) \\
          -e OMLX_API_KEY \\
          -v \(q(projectPath)):/workspace \\
          -v \(q(agentHome.path)):/seed:ro \\
          -v \(q(sessionsDir.path)):/root/.pi/agent/sessions \\
          --entrypoint bash \(Self.imageName) -c 'cp -r /seed/. /root/.pi/agent/ && exec pi'
        echo
        echo "Sandbox exited. You can close this window."
        """
    }
}
