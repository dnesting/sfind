import Foundation
import SFindCore
import Testing

/// Paths removed at process exit (test deinit is unreliable for shared fixtures, and
/// these live in the user's $HOME).
private nonisolated(unsafe) var fixtureCleanupPaths: [String] = []
private let registerFixtureCleanup: Void = {
    atexit {
        for path in fixtureCleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}()

/// A fixture in a NON-hidden directory directly under $HOME — the only location
/// verified to be fully indexed with sub-second latency. /tmp and $TMPDIR are
/// unindexed or reduced-tier. Shared across tests: building and mdimporting one
/// fixture per test serializes on the indexer and takes minutes.
final class IndexedFixture: Sendable {
    // Immutable after init and only read by tests; safe to share.
    static let shared: IndexedFixture? = try? IndexedFixture()

    let root: String
    let indexed: Bool

    init() throws {
        _ = registerFixtureCleanup
        let root =
            FileManager.default.homeDirectoryForCurrentUser.path + "/sfind-itest-"
            + UUID().uuidString.prefix(8)
        self.root = root
        fixtureCleanupPaths.append(root)
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        func write(_ relative: String, size: Int) throws {
            try Data(repeating: 0x61, count: size)
                .write(to: URL(fileURLWithPath: root + "/" + relative))
        }
        try write("a.md", size: 100)
        try write("b.txt", size: 10)
        try write("sub/c.md", size: 27034)
        try write("docs/guide.md", size: 5)
        try write("old.md", size: 3)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 3600)],
            ofItemAtPath: root + "/old.md")

        let importer = Process()
        importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        importer.arguments = [root]
        try importer.run()
        importer.waitUntilExit()

        // Poll (never fixed-sleep) until the whole fixture is queryable.
        var indexed = false
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let query = Process()
            let pipe = Pipe()
            query.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            query.arguments = ["-onlyin", root, "kMDItemFSName == \"*.md\""]
            query.standardOutput = pipe
            try query.run()
            query.waitUntilExit()
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            if lines.count >= 4 {
                indexed = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        self.indexed = indexed
    }
}

/// True end-to-end: the sfind pipeline (MDQuery against the live index → post-filter
/// → print) versus /usr/bin/find, over expressions whose matches are all indexable.
// .serialized: concurrent MDQueryExecute calls deadlock under the test runner's
// parallel executor (the synchronous mode spins the calling thread's run loop).
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["SFIND_INTEGRATION"] == "1"),
    .serialized)
struct EndToEndParityTests {
    static let expressions: [[String]] = [
        ["-name", "*.md"],
        ["-iname", "*.MD"],
        ["-name", "*.md", "-size", "+1k"],
        ["-size", "53"],
        ["-type", "d"],
        ["-type", "f", "-mtime", "-1"],
        ["-mtime", "+0"],
        ["(", "-name", "*.md", "-o", "-name", "*.txt", ")", "-size", "+0c"],
        ["!", "-name", "*.md", "-type", "f"],
        ["-maxdepth", "1", "-type", "f"],
        ["-mindepth", "1", "-type", "d"],
    ]

    @Test(arguments: expressions.indices)
    func endToEndMatchesFind(_ index: Int) throws {
        let fixture = try #require(IndexedFixture.shared)
        try #require(fixture.indexed, "fixture never became queryable within 60s")
        let tokens = Self.expressions[index]

        let oracle = Process()
        let pipe = Pipe()
        oracle.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        oracle.arguments = [fixture.root] + tokens
        oracle.standardOutput = pipe
        try oracle.run()
        let expected = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "\n").map(String.init).sorted()
        oracle.waitUntilExit()

        let sink = CollectingSink()
        let status = SFindCLI.run(arguments: [fixture.root] + tokens, sink: sink)
        #expect(sink.lines.sorted() == expected, "tokens: \(tokens)")
        #expect(status == oracle.terminationStatus, "tokens: \(tokens)")
    }

    @Test func exprStringEndToEnd() throws {
        let fixture = try #require(IndexedFixture.shared)
        try #require(fixture.indexed)
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: [fixture.root, "--expr", "(-name \"*.md\" -o -name \"*.txt\") -size +0c"],
            sink: sink)
        #expect(status == 0)
        #expect(sink.lines.count == 5)
    }

    @Test func missingRootDiagnostics() throws {
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: ["/nonexistent-sfind-path", "-name", "x"], sink: sink)
        #expect(status == 1)
        #expect(sink.diagnostics.first?.contains("No such file or directory") == true)
    }
}
