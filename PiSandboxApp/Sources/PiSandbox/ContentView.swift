import SwiftUI

struct StatusRow: View {
    let title: String
    let detail: String
    let health: Health
    var actionTitle: String?
    var action: (() -> Void)?
    var disabled = false

    var color: Color {
        switch health {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .unknown: .gray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).disabled(disabled)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Setup") {
                StatusRow(
                    title: "Podman",
                    detail: state.podmanPath ?? "Not installed",
                    health: state.podmanPath == nil ? .bad : .ok,
                    actionTitle: state.podmanPath == nil ? "Install" : nil,
                    action: { Task { await state.installPodman() } },
                    disabled: state.busy != nil)
                StatusRow(
                    title: "Podman machine (Linux VM)",
                    detail: machineDetail,
                    health: machineHealth,
                    actionTitle: machineAction.0,
                    action: machineAction.1,
                    disabled: state.busy != nil || state.podmanPath == nil)
                StatusRow(
                    title: "Sandbox image",
                    detail: state.imageBuilt ? "pi-sandbox built" : "Not built (built automatically on first launch)",
                    health: state.imageBuilt ? .ok : .warn,
                    actionTitle: state.machine == .running ? (state.imageBuilt ? "Rebuild" : "Build") : nil,
                    action: { Task { await state.buildImage() } },
                    disabled: state.busy != nil)
                StatusRow(
                    title: "Model server",
                    detail: serverDetail,
                    health: serverHealth,
                    actionTitle: "Check",
                    action: { Task { await state.probeServer() } })
            }

            Section("Model server (OpenAI-compatible)") {
                HStack {
                    TextField("Host", text: $state.serverHost)
                    TextField("Port", text: $state.serverPort).frame(width: 80)
                }
                HStack {
                    if state.showKey {
                        TextField("API key", text: $state.apiKey)
                    } else {
                        SecureField("API key", text: $state.apiKey)
                    }
                    Button(state.showKey ? "Hide" : "Show") { state.showKey.toggle() }
                }
                Picker("Model", selection: $state.model) {
                    if state.model.isEmpty { Text("—").tag("") }
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                Text("Runs on this Mac. The sandbox reaches it as host.containers.internal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Project") {
                HStack {
                    Text(state.projectPath.isEmpty ? "No folder chosen" : state.projectPath)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(state.projectPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { state.chooseProject() }
                }
                Text("Pi runs in yolo mode: it can edit or delete anything in this folder, and nothing else. Use git.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        Task { await state.launch() }
                    } label: {
                        Label("Launch Pi", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canLaunch)

                    Button("Stop all sandboxes (\(state.runningSandboxes))") {
                        Task { await state.stopSandboxes() }
                    }
                    .disabled(state.runningSandboxes == 0 || state.busy != nil)

                    Spacer()
                    if let busy = state.busy {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption)
                    }
                }
                HStack {
                    Button("Edit AGENTS.md & skills…") { state.openAgentFolder() }
                    Button("Reset to defaults") { state.resetGuidance() }
                }
            }

            Section("Log") {
                ScrollView {
                    Text(state.log.isEmpty ? "—" : state.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
    }

    var modelChoices: [String] {
        var m = state.models
        if !state.model.isEmpty && !m.contains(state.model) { m.insert(state.model, at: 0) }
        return m
    }

    var machineDetail: String {
        switch state.machine {
        case .unknown: "Unknown"
        case .missing: "Not created"
        case .stopped: "Stopped"
        case .running: "Running"
        }
    }
    var machineHealth: Health {
        switch state.machine {
        case .running: .ok
        case .stopped, .missing: .warn
        case .unknown: .unknown
        }
    }
    var machineAction: (String?, (() -> Void)?) {
        switch state.machine {
        case .missing: ("Create & start", { Task { await state.createMachine() } })
        case .stopped: ("Start", { Task { await state.startMachine() } })
        case .running: ("Stop", { Task { await state.stopMachine() } })
        case .unknown: (nil, nil)
        }
    }
    var serverDetail: String {
        switch state.server {
        case .unknown: "Checking…"
        case .down: "Not reachable at \(state.serverHost):\(state.serverPort)"
        case .unauthorized: "Reachable, but API key rejected"
        case .ok(let m): "Connected, \(m.count) model\(m.count == 1 ? "" : "s")"
        }
    }
    var serverHealth: Health {
        switch state.server {
        case .ok: .ok
        case .unauthorized: .warn
        case .down: .bad
        case .unknown: .unknown
        }
    }
}
