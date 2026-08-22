import Darwin
import Foundation
import SFindCore

/// A disposable on-disk fixture tree plus a walked candidate list (ArraySource input).
/// Lives in the system temp directory — deliberately outside Spotlight coverage, which
/// is fine: these tests exercise the post-filter, not the index.
final class TempTree {
    let root: String

    init() throws {
        // No "find" in the prefix: fixture paths appear in -path/-regex matches.
        root = NSTemporaryDirectory() + "sf-tree-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    func file(
        _ relative: String, size: Int = 0, mtime: Date? = nil, mode: mode_t? = nil
    ) throws -> String {
        let path = root + "/" + relative
        let data = Data(repeating: 0x61, count: size)
        try data.write(to: URL(fileURLWithPath: path))
        if let mode {
            chmod(path, mode)
        }
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: path)
        }
        return path
    }

    @discardableResult
    func symlink(_ relative: String, to destination: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
        return path
    }

    /// All paths in the tree (including the root itself), as find would visit them.
    func candidates() -> [Candidate] {
        var result = [Candidate(path: root, depth: 0)]
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil,
            options: [.producesRelativePathURLs])
        {
            for case let url as URL in enumerator {
                let path = root + "/" + url.relativePath
                result.append(Candidate.under(root: root, path: path))
            }
        }
        return result
    }
}

/// Runs an expression through the parser → evaluator over the given candidates.
enum Filter {
    static func run(
        _ tokens: [String], root: String, candidates: [Candidate], now: Date = Date(),
        promptResponder: ((String) -> Bool)? = nil
    ) throws -> (lines: [String], text: String, status: Int32, diagnostics: [String]) {
        // Leading option bundles (-L, -E, -s, …) must precede the path operand.
        let optionCount = tokens.prefix { token in
            token.count > 1 && token.hasPrefix("-")
                && token.dropFirst().allSatisfy { "HLPEXdsx".contains($0) }
        }.count
        let arguments =
            Array(tokens.prefix(optionCount)) + [root] + Array(tokens.dropFirst(optionCount))
        let command = try CommandParser().parse(arguments)
        let sink = CollectingSink()
        let runner = Runner(
            command: command, environment: .live(now: now), sink: sink,
            promptResponder: promptResponder)
        let status = runner.run(source: ArraySource(candidates))
        return (sink.lines, sink.text, status, sink.diagnostics)
    }

    /// Convenience: matched paths relative to the tree root ("" is the root itself).
    static func relativeMatches(
        _ tokens: [String], in tree: TempTree, now: Date = Date()
    ) throws -> [String] {
        let (lines, _, _, _) = try run(
            tokens, root: tree.root, candidates: tree.candidates(), now: now)
        return lines.map { line in
            line == tree.root
                ? "." : String(line.dropFirst(tree.root.count + 1))
        }.sorted()
    }
}
