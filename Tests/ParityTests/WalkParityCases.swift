import Foundation
import SFindCore
import Testing

/// The full CLI pipeline with `--walk=only` (the HybridSource's plain walk; the index
/// is never consulted) versus /usr/bin/find over the ParityTree. Sorted output and
/// exit status must match exactly.
enum WalkParity {
    /// Splits leading option bundles (they must precede the path operand) and inserts
    /// the walk flag after the root.
    static func arguments(_ tokens: [String], root: String, walk: String) -> [String] {
        let optionCount = tokens.prefix { token in
            token.count > 1 && token.hasPrefix("-")
                && token.dropFirst().allSatisfy { "HLPEXdsx".contains($0) }
        }.count
        return Array(tokens.prefix(optionCount)) + [root, walk]
            + Array(tokens.dropFirst(optionCount))
    }

    static func sfind(
        _ tokens: [String], root: String, walk: String = "--walk=only", nulSeparated: Bool = false
    ) -> (output: [String], text: String, status: Int32, diagnostics: [String]) {
        let sink = CollectingSink()
        let status = SFindCLI.run(arguments: arguments(tokens, root: root, walk: walk), sink: sink)
        let separator: Character = nulSeparated ? "\0" : "\n"
        let lines = sink.text.split(separator: separator, omittingEmptySubsequences: true)
            .map(String.init).sorted()
        return (lines, sink.text, status, sink.diagnostics)
    }

    /// /usr/bin/find's raw output text (traversal order preserved).
    static func findText(_ tokens: [String], root: String) throws -> (text: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = arguments(tokens, root: root, walk: "").filter { !$0.isEmpty }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

@Suite struct WalkOnlyParityCases {
    static let expressions: [[String]] = [
        [],
        ["-type", "l"],
        ["-type", "f"],
        ["-type", "d"],
        ["-name", ".*"],
        ["-name", "*.md"],
        ["-L", "-type", "f"],
        ["-L", "-type", "l"],
        ["-L"],
        ["-H"],
        ["-H", "-type", "l"],
        ["-maxdepth", "1"],
        ["-maxdepth", "0"],
        ["-mindepth", "2"],
        ["-mindepth", "1", "-maxdepth", "2", "-type", "d"],
        ["-name", "src", "-prune", "-o", "-print"],
        ["-type", "d", "-name", "deep", "-prune", "-o", "-name", "*.bin", "-print"],
        ["-path", "*/src/*", "-type", "f"],
        ["-path", "*/nested/*"],
        ["-regex", ".*\\.md"],
        ["-d"],
        ["-d", "-type", "d"],
        ["-x"],
        ["-x", "-type", "f"],
        ["-empty"],
        ["-type", "f", "-empty"],
        ["-lname", "a.md"],
        ["-links", "2"],
        ["-size", "+1k"],
        ["!", "-name", "*.md"],
        ["-name", "*.md", "-o", "-name", "*.txt"],
        ["-false"],
        ["-name", "*.md", "-print", "-print"],
    ]

    @Test(arguments: expressions.indices)
    func walkOnlyMatchesFind(_ index: Int) throws {
        let tree = try ParityTree()
        let tokens = Self.expressions[index]
        let oracle = try Parity.findOracle(tokens, root: tree.root)
        let ours = WalkParity.sfind(tokens, root: tree.root)
        #expect(ours.output == oracle.output, "tokens: \(tokens)")
        #expect(ours.status == oracle.status, "status for tokens: \(tokens)")
    }

    @Test func sortedOrderMatchesFindExactly() throws {
        let tree = try ParityTree()
        let tokens = ["-s", "-name", "*.md"]
        let oracle = try WalkParity.findText(tokens, root: tree.root)
        let ours = WalkParity.sfind(tokens, root: tree.root)
        #expect(ours.text == oracle.text)
        #expect(ours.status == oracle.status)
        #expect(!ours.text.isEmpty)

        let mixed = ["-s", "-name", "*.md", "-o", "-type", "d"]
        #expect(
            WalkParity.sfind(mixed, root: tree.root).text
                == (try WalkParity.findText(mixed, root: tree.root)).text)
    }

    @Test func unsortedOrderMatchesFindTraversal() throws {
        // Without -s the walk streams in readdir pre-order, exactly as find prints.
        let tree = try ParityTree()
        for tokens in [[], ["-d"], ["-type", "f"]] {
            let oracle = try WalkParity.findText(tokens, root: tree.root)
            let ours = WalkParity.sfind(tokens, root: tree.root)
            #expect(ours.text == oracle.text, "tokens: \(tokens)")
        }
    }

    @Test func print0Parity() throws {
        let tree = try ParityTree()
        let tokens = ["-name", "*.md", "-print0"]
        let oracle = try Parity.findOracle(tokens, root: tree.root, nulSeparated: true)
        let ours = WalkParity.sfind(tokens, root: tree.root, nulSeparated: true)
        #expect(ours.output == oracle.output)
        #expect(!ours.output.isEmpty)
        #expect(!ours.text.contains("\n"))
    }

    @Test func walkOnlyEmitsNoIndexWarnings() throws {
        let tree = try ParityTree()
        let ours = WalkParity.sfind(["-type", "l"], root: tree.root)
        #expect(ours.diagnostics.isEmpty)
        #expect(ours.output.count == 2)
    }

    @Test func multipleRoots() throws {
        let tree = try ParityTree()
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: [tree.root + "/src", tree.root + "/docs", "--walk=only", "-type", "f"],
            sink: sink)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [tree.root + "/src", tree.root + "/docs", "-type", "f"]
        process.standardOutput = pipe
        try process.run()
        let expected = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(sink.text == expected)
        #expect(status == process.terminationStatus)
    }
}

/// `--walk` (gaps mode) over a tree the index does not cover: the exhaustive prefix
/// walk finishes within its budget, so the output is a plain find traversal. The
/// index-only comparison consults Spotlight (an empty result for this scope).
// .serialized: concurrent MDQuery executions deadlock under the parallel executor.
@Suite(.serialized) struct WalkGapsParityCases {
    static let expressions: [[String]] = [
        [],
        ["-type", "l"],
        ["-name", ".*"],
        ["-L", "-type", "f"],
        ["-maxdepth", "1"],
        ["-name", "src", "-prune", "-o", "-print"],
        ["-d"],
        ["-empty"],
    ]

    @Test(arguments: expressions.indices)
    func gapsWalkOfUnindexedTreeMatchesFind(_ index: Int) throws {
        let tree = try ParityTree()
        let tokens = Self.expressions[index]
        let oracle = try Parity.findOracle(tokens, root: tree.root)
        let ours = WalkParity.sfind(tokens, root: tree.root, walk: "--walk")
        #expect(ours.output == oracle.output, "tokens: \(tokens)")
        #expect(ours.status == oracle.status, "status for tokens: \(tokens)")
    }

    @Test func walkOutputIsASupersetOfIndexOnly() throws {
        let tree = try ParityTree()
        let walked = WalkParity.sfind(["-type", "f"], root: tree.root, walk: "--walk")
        let indexOnly = WalkParity.sfind(["-type", "f"], root: tree.root, walk: "--walk=off")
        #expect(Set(indexOnly.output).isSubset(of: Set(walked.output)))
        #expect(walked.output.count > indexOnly.output.count)
    }
}
