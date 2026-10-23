import Foundation

struct ShellResult {
    let code: Int32
    let out: String
    var ok: Bool { code == 0 }
}

final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

enum Shell {
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/opt/podman/bin"

    static func find(_ tool: String) -> String? {
        for dir in extraPath.split(separator: ":") {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a process, merging stdout+stderr. `onOutput` streams chunks as they arrive.
    static func run(_ exe: String, _ args: [String], onOutput: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LockedBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let s = String(decoding: data, as: UTF8.self)
                buffer.append(s)
                onOutput?(s)
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    let s = String(decoding: rest, as: UTF8.self)
                    buffer.append(s)
                    onOutput?(s)
                }
                cont.resume(returning: ShellResult(code: proc.terminationStatus, out: buffer.value))
            }
            do { try process.run() } catch {
                cont.resume(returning: ShellResult(code: 127, out: "\(error)"))
            }
        }
    }
}
