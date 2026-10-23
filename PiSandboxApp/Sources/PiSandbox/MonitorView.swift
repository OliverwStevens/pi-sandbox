import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: MonitorState
    let running: Int

    var levelColor: Color {
        switch monitor.level {
        case "Low": .green
        case "Elevated": .yellow
        case "High": .orange
        default: .red
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            riskCard
            progressCard
            signalsCard
            findingsCard
        }
    }

    // MARK: risk gauge

    var riskCard: some View {
        Card(title: "Risk", symbol: "gauge.with.dots.needle.50percent") {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.1), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(monitor.score, 2)) / 100)
                        .stroke(levelColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(monitor.score)").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(monitor.level).font(.title2.bold()).foregroundStyle(levelColor)
                    Text(monitor.verdict).font(.callout).foregroundStyle(.secondary)
                    Text(counts).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var counts: String {
        let f = monitor.findings
        let c = f.filter { $0.severity == .critical }.count
        let h = f.filter { $0.severity == .high }.count
        let m = f.filter { $0.severity == .medium }.count
        let b = f.filter { $0.blocked }.count
        return "\(c) critical · \(h) high · \(m) medium · \(b) blocked by the sandbox"
    }

    // MARK: progress

    var progressCard: some View {
        Card(title: "What the model is doing", symbol: "brain") {
            HStack {
                Text(monitor.stats.status).fontWeight(.medium)
                Spacer()
                if monitor.stats.phase != "–" {
                    Text(monitor.stats.phase)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            if monitor.stats.looping {
                Label("Repeating: \(monitor.stats.loopDetail)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    stat("Steps", "\(monitor.stats.steps)")
                    stat("Tokens", compact(monitor.stats.tokens))
                    stat("Tool errors", "\(monitor.stats.errors)")
                    stat("Files written", "\(monitor.stats.filesTouched)")
                }
            }
            if !monitor.stats.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(monitor.stats.toolCalls.sorted(by: { $0.value > $1.value }), id: \.key) { name, n in
                        HStack(spacing: 8) {
                            Text(name).font(.caption).frame(width: 48, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.6))
                                    .frame(width: geo.size.width * CGFloat(n) / CGFloat(maxCalls))
                            }
                            .frame(height: 8)
                            Text("\(n)").font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
            if !monitor.stats.model.isEmpty {
                Text("Model: \(monitor.stats.model)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var maxCalls: Int { max(monitor.stats.toolCalls.values.max() ?? 1, 1) }

    func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }

    // MARK: live signals

    var signalsCard: some View {
        Card(title: "Live signals", symbol: "waveform.path.ecg") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    stat("Sandboxes", "\(running)")
                    stat("CPU", monitor.cpu)
                    stat("Memory", monitor.memory)
                    stat("Project files changed", "\(monitor.filesChanged)")
                }
            }
            Divider()
            Text("Network connections seen").font(.subheadline.weight(.medium))
            if monitor.network.isEmpty {
                Text(running > 0 ? "None yet." : "Start a sandbox to watch its connections.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.network) { o in
                    HStack {
                        Image(systemName: o.expected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(o.expected ? Color.green : Color.orange)
                        Text("\(o.connection.ip):\(o.connection.port)").font(.system(.callout, design: .monospaced))
                        Text(o.expected ? "model server (expected)" : "unexpected")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: findings

    var findingsCard: some View {
        Card(title: "Findings", symbol: "list.bullet.rectangle") {
            if monitor.findings.isEmpty {
                Text("Nothing suspicious. Rules check shell commands, file edits and reads, new host-executed files (git hooks, CI, scripts), symlinks, mass deletes and outbound connections.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.findings.prefix(60))) { f in
                    FindingRow(finding: f)
                    Divider()
                }
                if monitor.findings.count > 60 {
                    Text("+ \(monitor.findings.count - 60) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Heuristic rules, not a guarantee. A quiet dashboard does not prove a session was safe.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct FindingRow: View {
    let finding: Finding

    var color: Color {
        switch finding.severity {
        case .low: .gray
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(finding.severity.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(color))
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.category).font(.callout.weight(.medium))
                    if finding.blocked {
                        Label("blocked", systemImage: "lock.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                Text(finding.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let t = finding.time {
                Text(t, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
