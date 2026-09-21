import Foundation
import SFindCore
import Testing

/// Paths removed at process exit (the fixture lives in the user's $HOME).
private nonisolated(unsafe) var walkFixtureCleanupPaths: [String] = []
private let registerWalkFixtureCleanup: Void = {
    atexit {
        for path in walkFixtureCleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}()

/// A fixture directly under $HOME (the only location verified to be fully indexed with
/// sub-second latency) mixing indexed files, text content, and everything Spotlight
/// leaves out: dot entries, symlinks, and a .noindex subtree.
final class WalkFixture: Sendable {
    static let shared: WalkFixture? = try? WalkFixture()

    let root: String
    let indexed: Bool

    init() throws {
        _ = registerWalkFixtureCleanup
        let root =
            FileManager.default.homeDirectoryForCurrentUser.path + "/sfind-itest-walk-"
            + UUID().uuidString.prefix(8)
        self.root = root
        walkFixtureCleanupPaths.append(root)
        let fm = FileManager.default
        for dir in [
            "a/node_modules/pkg", "b/node_modules/.bin", "plain/deep", ".hidden", "Cache.noindex",
        ] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ text: String) throws {
            try text.write(toFile: root + "/" + relative, atomically: true, encoding: .utf8)
        }
        try write("a/note.txt", "zebrafish swim upstream\n")
        try write("plain/other.txt", "plain words\n")
        try write("a/node_modules/pkg/index.js", "module.exports = 1;\n")
        try write("b/node_modules/lib.js", "module.exports = 2;\n")
        try write(".hidden/secret.txt", "hidden\n")
        try write(".dotfile", "dot\n")
        try write("Cache.noindex/cached.txt", "cached\n")
        try write("plain/deep/file.txt", "deep\n")
        try fm.createSymbolicLink(
            atPath: root + "/b/node_modules/.bin/link", withDestinationPath: "../lib.js")
        try fm.createSymbolicLink(
            atPath: root + "/a/link.txt", withDestinationPath: "note.txt")

        let importer = Process()
        importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        importer.arguments = [root]
        try importer.run()
        importer.waitUntilExit()

        func mdfind(_ query: String) throws -> [String] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", root, query]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n").map(String.init)
        }

        // Poll until both the file names and the text content are queryable.
        var indexed = false
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let content = try mdfind("kMDItemTextContent == \"zebrafish\"cd")
            let scripts = try mdfind("kMDItemFSName == \"*.js\"")
            if content.contains(where: { $0.hasSuffix("/a/note.txt") }), scripts.count == 2 {
                indexed = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        self.indexed = indexed
    }
}

// .serialized: concurrent MDQueryExecute calls deadlock under the test runner's
// parallel executor.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["SFIND_INTEGRATION"] == "1"),
    .serialized)
struct WalkAndContentTests {
    func fixture() throws -> WalkFixture {
        let fixture = try #require(WalkFixture.shared)
        try #require(fixture.indexed, "fixture never became queryable within 60s")
        return fixture
    }

    func find(_ tokens: [String], root: String) throws -> (lines: [String], status: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [root] + tokens
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let lines = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "\n").map(String.init).sorted()
        process.waitUntilExit()
        return (lines, process.terminationStatus)
    }

    func sfind(_ arguments: [String], root: String) -> (
        lines: [String], status: Int32, diagnostics: [String]
    ) {
        let sink = CollectingSink()
        let status = SFindCLI.run(arguments: [root] + arguments, sink: sink)
        return (sink.lines.sorted(), status, sink.diagnostics)
    }

    /// Whether a find output line names something Spotlight never indexes here: a dot
    /// entry, the .noindex subtree, or a symlink.
    func unindexed(_ path: String, root: String) -> Bool {
        let relative = path.dropFirst(root.count)
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return true }
        if relative.contains(".noindex") { return true }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    @Test func walkMatchesFindExactly() throws {
        let fixture = try fixture()
        let oracle = try find([], root: fixture.root)
        let ours = sfind(["--walk"], root: fixture.root)
        #expect(ours.lines == oracle.lines)
        #expect(ours.status == oracle.status)
        #expect(ours.lines.count == 21)
    }

    @Test func walkFillsTheIndexGaps() throws {
        let fixture = try fixture()
        let indexOnly = sfind([], root: fixture.root)
        let walked = sfind(["--walk"], root: fixture.root)
        let gaps = [
            "/.dotfile", "/.hidden/secret.txt", "/Cache.noindex/cached.txt",
            "/a/link.txt", "/b/node_modules/.bin/link",
        ].map { fixture.root + $0 }
        for gap in gaps {
            #expect(!indexOnly.lines.contains(gap), "\(gap)")
            #expect(walked.lines.contains(gap), "\(gap)")
        }
        #expect(indexOnly.lines.contains(fixture.root + "/a/note.txt"))
        #expect(indexOnly.lines.contains(fixture.root + "/b/node_modules/lib.js"))
        #expect(Set(indexOnly.lines).isSubset(of: Set(walked.lines)))
    }

    @Test func walkSymlinksMatchFind() throws {
        let fixture = try fixture()
        let oracle = try find(["-type", "l"], root: fixture.root)
        let ours = sfind(["--walk", "-type", "l"], root: fixture.root)
        #expect(ours.lines == oracle.lines)
        #expect(ours.lines.count == 2)
        #expect(ours.status == 0)
    }

    @Test func walkWithAnchoredPathFindsSymlinkUnderAnchor() throws {
        let fixture = try fixture()
        let ours = sfind(
            ["--walk", "-path", "*/node_modules/*", "-type", "l"], root: fixture.root)
        #expect(ours.lines == [fixture.root + "/b/node_modules/.bin/link"])
        #expect(ours.status == 0)
    }

    @Test func indexOnlyAnchoredPathOmitsOnlyDotEntries() throws {
        let fixture = try fixture()
        let oracle = try find(["-path", "*/node_modules/*"], root: fixture.root)
        let expected = oracle.lines.filter { !$0.contains("/.bin") }
        #expect(expected.count == oracle.lines.count - 2)
        let ours = sfind(["-path", "*/node_modules/*"], root: fixture.root)
        #expect(ours.lines == expected)
        #expect(ours.status == 0)
    }

    @Test func contentMatchesIndexedText() throws {
        let fixture = try fixture()
        let note = fixture.root + "/a/note.txt"
        #expect(sfind(["-content", "zebrafish"], root: fixture.root).lines == [note])
        #expect(sfind(["-content", "zebra*"], root: fixture.root).lines == [note])
        #expect(sfind(["-content", "ZEBRAFISH"], root: fixture.root).lines == [note])
        #expect(sfind(["-content", "zebrafish upstream"], root: fixture.root).lines == [note])
        #expect(sfind(["-content", "nosuchword"], root: fixture.root).lines.isEmpty)
        #expect(sfind(["-content", "zebrafish nosuchword"], root: fixture.root).lines.isEmpty)
        #expect(sfind(["-content", "zebrafish"], root: fixture.root).status == 0)
    }

    @Test func negatedContentExcludesOnlyTheMatchingFile() throws {
        let fixture = try fixture()
        let oracle = try find(["-type", "f"], root: fixture.root)
        let expected = oracle.lines.filter {
            !unindexed($0, root: fixture.root) && !$0.hasSuffix("/a/note.txt")
        }
        #expect(expected.count == 4)
        let ours = sfind(["-type", "f", "!", "-content", "zebrafish"], root: fixture.root)
        #expect(ours.lines == expected)
        #expect(ours.status == 0)
    }

    @Test func contentUnderDisjunction() throws {
        let fixture = try fixture()
        let ours = sfind(
            ["(", "-content", "zebrafish", "-o", "-name", "other.txt", ")"], root: fixture.root)
        #expect(ours.lines == [fixture.root + "/a/note.txt", fixture.root + "/plain/other.txt"])
    }

    @Test func contentWithWalkStillComesFromTheIndex() throws {
        let fixture = try fixture()
        let note = fixture.root + "/a/note.txt"
        #expect(sfind(["--walk", "-content", "zebrafish"], root: fixture.root).lines == [note])
        let negated = sfind(
            ["--walk", "-type", "f", "!", "-content", "zebrafish"], root: fixture.root)
        let oracle = try find(["-type", "f"], root: fixture.root)
        #expect(negated.lines == oracle.lines.filter { $0 != note })
    }

    @Test func walkOnlyCannotAnswerContent() throws {
        let fixture = try fixture()
        let ours = sfind(["--walk=only", "-content", "zebrafish"], root: fixture.root)
        #expect(ours.lines.isEmpty)
        #expect(ours.diagnostics.contains { $0.contains("--walk=only") && $0.contains("-content") })
        #expect(ours.status == 0)
    }

    @Test func progressDoesNotDisturbOutput() throws {
        let fixture = try fixture()
        let plain = sfind(["--walk", "-name", "*.txt"], root: fixture.root)
        let withProgress = sfind(["--progress", "--walk", "-name", "*.txt"], root: fixture.root)
        #expect(withProgress.status == 0)
        #expect(withProgress.lines == plain.lines)
        #expect(withProgress.lines == (try find(["-name", "*.txt"], root: fixture.root)).lines)
        let indexOnly = sfind(["--progress", "-name", "*.txt"], root: fixture.root)
        #expect(indexOnly.status == 0)
        #expect(indexOnly.lines == sfind(["-name", "*.txt"], root: fixture.root).lines)
    }
}
