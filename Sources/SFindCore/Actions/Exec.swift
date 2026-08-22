import Darwin
import Foundation

/// Spawns a child via posix_spawnp (PATH resolution like execvp), optionally from a
/// working directory, inheriting stdio. Returns the exit status, or nil on spawn
/// failure (errno preserved in the message via the caller's diagnostic).
func spawnAndWait(argv: [String], directory: String?) -> Int32? {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    if let directory {
        posix_spawn_file_actions_addchdir_np(&fileActions, directory)
    }

    var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgv.append(nil)
    defer { cArgv.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, argv[0], &fileActions, &attr, cArgv, environ)
    guard rc == 0 else { return nil }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { return nil }
    }
    if status & 0x7F == 0 {
        return (status >> 8) & 0xFF
    }
    return 128 + (status & 0x7F)  // terminated by signal
}

/// State for one -exec/-execdir/-ok/-okdir primary. The `;` form runs per file; the
/// `{} +` form accumulates paths and runs in batches (per directory for -execdir,
/// matching find), flushed finally by Evaluator.finish().
final class ExecState {
    let spec: ExecSpec
    let sink: OutputSink
    /// Injectable for tests; the default prompts on stderr and reads stdin (-ok).
    let promptResponder: (String) -> Bool
    private var batch: [String] = []
    private var batchBytes = 0
    private var batchDirectory: String?
    /// A `{} +` child exited nonzero: find's overall exit status becomes 1.
    private(set) var batchFailed = false

    init(spec: ExecSpec, sink: OutputSink, promptResponder: ((String) -> Bool)?) {
        self.spec = spec
        self.sink = sink
        self.promptResponder =
            promptResponder
            ?? { prompt in
                FileHandle.standardError.write(Data("\(prompt)? ".utf8))
                guard let line = readLine(strippingNewline: true) else { return false }
                return line.lowercased().hasPrefix("y")
            }
    }

    /// Evaluates the primary for one file. Returns the predicate result.
    func run(path: String, sawError: inout Bool) -> Bool {
        let (directory, substitution) = target(path: path)
        if spec.batch {
            // Batch form is always true; children run later.
            if batchDirectory != directory || batchBytes > 128 * 1024 || batch.count >= 4096 {
                flush(sawError: &sawError)
            }
            batchDirectory = directory
            batch.append(substitution)
            batchBytes += substitution.utf8.count + 1
            return true
        }
        let argv = spec.argv.map { $0.replacingOccurrences(of: "{}", with: substitution) }
        if spec.prompted {
            let rendered = argv.joined(separator: " ")
            if !promptResponder("\"\(rendered)\"") {
                return false
            }
        }
        sink.flush()  // keep -print output ordered ahead of child output
        guard let status = spawnAndWait(argv: argv, directory: directory) else {
            sink.diagnostic("\(argv[0]): \(String(cString: strerror(errno)))")
            sawError = true
            return false
        }
        return status == 0
    }

    func flush(sawError: inout Bool) {
        guard !batch.isEmpty else { return }
        let argv = Array(spec.argv.dropLast()) + batch
        batch.removeAll()
        batchBytes = 0
        sink.flush()
        guard let status = spawnAndWait(argv: argv, directory: batchDirectory) else {
            sink.diagnostic("\(argv[0]): \(String(cString: strerror(errno)))")
            sawError = true
            batchFailed = true
            return
        }
        if status != 0 {
            batchFailed = true
        }
    }

    /// -execdir runs from the file's directory with the unqualified name.
    private func target(path: String) -> (directory: String?, substitution: String) {
        guard spec.fromFileDirectory else { return (nil, path) }
        if let slash = path.lastIndex(of: "/") {
            let dir = slash == path.startIndex ? "/" : String(path[..<slash])
            return (dir, String(path[path.index(after: slash)...]))
        }
        return (".", path)
    }
}
