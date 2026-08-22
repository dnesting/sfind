import Foundation

/// Destination for action output (stdout) and diagnostics (stderr).
public protocol OutputSink: AnyObject {
    func write(_ bytes: [UInt8])
    func diagnostic(_ message: String)
    func flush()
}

extension OutputSink {
    func write(_ text: String) {
        write(Array(text.utf8))
    }
}

/// Buffered writer over file handles (stdout/stderr for the real CLI).
public final class FileHandleSink: OutputSink {
    private let output: FileHandle
    private let errors: FileHandle
    private var buffer: [UInt8] = []
    private let bufferLimit = 1 << 16

    public init(output: FileHandle = .standardOutput, errors: FileHandle = .standardError) {
        self.output = output
        self.errors = errors
    }

    public func write(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        if buffer.count >= bufferLimit {
            flush()
        }
    }

    public func diagnostic(_ message: String) {
        flush()
        errors.write(Data("sfind: \(message)\n".utf8))
    }

    public func flush() {
        if !buffer.isEmpty {
            output.write(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

/// Collects output in memory for tests.
public final class CollectingSink: OutputSink {
    public private(set) var bytes: [UInt8] = []
    public private(set) var diagnostics: [String] = []

    public init() {}

    public func write(_ bytes: [UInt8]) {
        self.bytes.append(contentsOf: bytes)
    }

    public func diagnostic(_ message: String) {
        diagnostics.append(message)
    }

    public func flush() {}

    public var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Newline-separated output lines (for -print output).
    public var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
