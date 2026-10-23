import AppKit
import SwiftUI

// MARK: - building blocks

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct StatusRow: View {
    let title: String
    let detail: String
    let health: Health
    var actionTitle: String?
    var action: (() -> Void)?
    var disabled = false

    var symbol: (String, Color) {
        switch health {
        case .ok: ("checkmark.circle.fill", .green)
        case .warn: ("exclamationmark.triangle.fill", .orange)
        case .bad: ("xmark.octagon.fill", .red)
        case .unknown: ("circle.dashed", .gray)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.0)
                .foregroundStyle(symbol.1)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).disabled(disabled)
            }
        }
    }
}

struct TestRow: View {
    let result: TestResult

    var symbol: (String, Color) {
        switch result.status {
        case "PASS": ("checkmark.circle.fill", .green)
        case "WARN": ("exclamationmark.triangle.fill", .orange)
        default: ("xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol.0).foregroundStyle(symbol.1).frame(width: 18)
            Text(result.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - main view

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                setupCard
                serverCard
                projectCard
                launchBar
                selfTestCard
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 640, idealHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pi Sandbox").font(.title2.bold())
                Text("Run the pi coding agent in a locked-down container")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(state.isReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(state.isReady ? "Ready" : "Needs setup").font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    // MARK: setup

    var setupCard: some View {
        Card(title: "Setup", symbol: "checklist") {
            StatusRow(
                title: "Podman",
                detail: state.podmanPath ?? "Not installed",
                health: state.podmanPath == nil ? .bad : .ok,
                actionTitle: state.podmanPath == nil ? "Install" : nil,
                action: { Task { await state.installPodman() } },
                disabled: state.busy != nil)
            Divider()
            StatusRow(
                title: "Podman machine",
                detail: machineDetail,
                health: machineHealth,
                actionTitle: machineAction.0,
                action: machineAction.1,
                disabled: state.busy != nil || state.podmanPath == nil)
            Divider()
            StatusRow(
                title: "Sandbox image",
                detail: state.imageBuilt ? "pi-sandbox is built" : "Not built yet. It builds automatically on first launch.",
                health: state.imageBuilt ? .ok : .warn,
                actionTitle: state.machine == .running ? (state.imageBuilt ? "Rebuild" : "Build") : nil,
                action: { Task { await state.buildImage() } },
                disabled: state.busy != nil)
            Divider()
            StatusRow(
                title: "Model server",
                detail: serverDetail,
                health: serverHealth,
                actionTitle: "Check",
                action: { Task { await state.probeServer() } })
        }
    }

    // MARK: server

    var serverCard: some View {
        Card(title: "Model server", symbol: "server.rack") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    HStack {
                        TextField("Host", text: $state.serverHost)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", text: $state.serverPort).frame(width: 70)
                    }
                }
                GridRow {
                    Text("API key").foregroundStyle(.secondary)
                    HStack {
                        if state.showKey {
                            TextField("API key", text: $state.apiKey)
                        } else {
                            SecureField("API key", text: $state.apiKey)
                        }
                        Button {
                            state.showKey.toggle()
                        } label: {
                            Image(systemName: state.showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Picker("Model", selection: $state.model) {
                        if state.model.isEmpty { Text("—").tag("") }
                        ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("Any OpenAI-compatible server on this Mac (omlx, Ollama, LM Studio). The sandbox reaches it as host.containers.internal.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: project

    var projectCard: some View {
        Card(title: "Project", symbol: "folder") {
            HStack {
                Image(systemName: state.projectPath.isEmpty ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(state.projectPath.isEmpty ? "No folder chosen" : state.projectPath)
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(state.projectPath.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose…") { state.chooseProject() }
            }
            Label("Yolo mode: pi can edit or delete anything in this folder, and nothing else. Commit to git first.",
                  systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: launch

    var launchBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await state.launch() }
            } label: {
                Label("Launch Pi", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!state.canLaunch)

            Button {
                Task { await state.stopSandboxes() }
            } label: {
                Label("Stop (\(state.runningSandboxes))", systemImage: "stop.fill")
                    .padding(.vertical, 6)
            }
            .controlSize(.large)
            .disabled(state.runningSandboxes == 0 || state.busy != nil)
        }
        .overlay(alignment: .bottomLeading) {
            if let busy = state.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                .offset(y: 24)
            }
        }
        .padding(.bottom, state.busy == nil ? 0 : 24)
    }

    // MARK: self-test

    var selfTestCard: some View {
        Card(title: "Is it really sandboxed?", symbol: "lock.shield") {
            Text("Starts a throwaway container with the exact same restrictions and tries to break out. Takes a few seconds.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await state.runSelfTest() }
                } label: {
                    Label("Run self-test", systemImage: "checkmark.shield")
                }
                .disabled(state.busy != nil || state.podmanPath == nil)
                if state.selfTestRan { summary }
            }
            if !state.selfTest.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.selfTest) { TestRow(result: $0) }
                }
            }
        }
    }

    var summary: some View {
        let failed = state.selfTest.filter { $0.status == "FAIL" }.count
        let warned = state.selfTest.filter { $0.status == "WARN" }.count
        let passed = state.selfTest.filter { $0.status == "PASS" }.count
        let text = state.selfTest.isEmpty
            ? "No results"
            : failed > 0 ? "\(failed) failed" : "\(passed) passed" + (warned > 0 ? ", \(warned) warning\(warned == 1 ? "" : "s")" : "")
        return Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(failed > 0 ? Color.red : warned > 0 ? Color.orange : Color.green)
    }

    // MARK: footer

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Edit AGENTS.md & skills…") { state.openAgentFolder() }
                Button("Reset to defaults") { state.resetGuidance() }
                Spacer()
                Button(state.showLog ? "Hide log" : "Show log") { state.showLog.toggle() }
            }
            .buttonStyle(.link)
            .font(.callout)
            if state.showLog {
                ScrollView {
                    Text(state.log.isEmpty ? "—" : state.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            }
        }
    }

    // MARK: derived text

    var modelChoices: [String] {
        var m = state.models
        if !state.model.isEmpty && !m.contains(state.model) { m.insert(state.model, at: 0) }
        return m
    }

    var machineDetail: String {
        switch state.machine {
        case .unknown: "Unknown"
        case .missing: "Not created yet"
        case .stopped: "Stopped"
        case .running: "Running (the Linux VM that hosts containers)"
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
        case .down: "Not reachable at \(state.cleanHost):\(state.cleanPort)"
        case .unauthorized: "Reachable, but the API key was rejected"
        case .ok(let m): "Connected, \(m.count) model\(m.count == 1 ? "" : "s") available"
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
