import Darwin
import Foundation
import SFindCore

/// A fixture tree exercising most primaries, plus runners for both sides of the
/// comparison: /usr/bin/find (the oracle) and sfind's parser→evaluator machinery fed
/// by a plain filesystem walk (ArraySource). Because the walk sees everything find
/// sees — dotfiles and symlinks included — outputs must match EXACTLY; no divergence
/// annotations apply in this mode (those are Spotlight-tier concerns, covered by the
/// integration suite).
final class ParityTree {
    let root: String
    let referenceFile: String

    init() throws {
        // No "find" substring: paths appear in -path/-regex patterns.
        let root = NSTemporaryDirectory() + "sf-parity-" + UUID().uuidString
        self.root = root
        self.referenceFile = root + "/recent.log"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        func file(_ rel: String, size: Int = 0, mode: mode_t? = nil, ageSeconds: Int = 0) throws {
            let path = root + "/" + rel
            try Data(repeating: 0x61, count: size).write(to: URL(fileURLWithPath: path))
            if let mode { chmod(path, mode) }
            if ageSeconds > 0 {
                try fm.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-Double(ageSeconds))],
                    ofItemAtPath: path)
            }
        }

        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try fm.createDirectory(
            atPath: root + "/deep/nested/dir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/emptydir", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/.config", withIntermediateDirectories: true)

        try file("a.md", size: 100)
        try file("b.txt")
        try file("UPPER.MD", size: 5)
        try file("spa ce.txt", size: 1)
        try file("src/main.swift", size: 2048)
        try file("src/util.swift", size: 10)
        try file("docs/readme.md", size: 3)
        try file(".hidden", size: 1)
        try file(".config/settings", size: 4)
        try file("deep/nested/dir/blob.bin", size: 27034)
        try file("exec.sh", size: 20, mode: 0o755)
        try file("locked", size: 7, mode: 0o400)
        try file("old.log", size: 30, ageSeconds: 25 * 3600)
        try file("recent.log", size: 30, ageSeconds: 30 * 60)

        try fm.createSymbolicLink(
            atPath: root + "/link.md", withDestinationPath: "a.md")
        try fm.createSymbolicLink(
            atPath: root + "/broken", withDestinationPath: "missing-target")
        try fm.linkItem(atPath: root + "/a.md", toPath: root + "/hard.md")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Everything in the tree, walked without following symlinks (as find -P visits).
    func candidates() -> [Candidate] {
        var result = [Candidate(path: root, depth: 0)]
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil,
            options: [.producesRelativePathURLs])
        {
            for case let url as URL in enumerator {
                result.append(Candidate.under(root: root, path: root + "/" + url.relativePath))
            }
        }
        return result
    }
}

enum Parity {
    /// Splits leading option bundles (they must precede the path operand).
    private static func argumentsWithRoot(_ tokens: [String], root: String) -> [String] {
        let optionCount = tokens.prefix { token in
            token.count > 1 && token.hasPrefix("-")
                && token.dropFirst().allSatisfy { "HLPEXdsx".contains($0) }
        }.count
        return Array(tokens.prefix(optionCount)) + [root] + Array(tokens.dropFirst(optionCount))
    }

    static func findOracle(
        _ tokens: [String], root: String, nulSeparated: Bool = false
    ) throws -> (output: [String], status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = argumentsWithRoot(tokens, root: root)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let separator: Character = nulSeparated ? "\0" : "\n"
        let lines = text.split(separator: separator, omittingEmptySubsequences: true)
            .map(String.init).sorted()
        return (lines, process.terminationStatus)
    }

    static func sfind(
        _ tokens: [String], root: String, candidates: [Candidate], nulSeparated: Bool = false
    ) throws -> (output: [String], status: Int32) {
        let command = try CommandParser().parse(argumentsWithRoot(tokens, root: root))
        let sink = CollectingSink()
        let runner = Runner(command: command, environment: .live(), sink: sink)
        let status = runner.run(source: ArraySource(candidates))
        let separator: Character = nulSeparated ? "\0" : "\n"
        let lines = sink.text.split(separator: separator, omittingEmptySubsequences: true)
            .map(String.init).sorted()
        return (lines, status)
    }
}
