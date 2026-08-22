import Foundation
import Testing

/// Integration tests exercise a real Spotlight index. They are opt-in: set
/// SFIND_INTEGRATION=1 (CI gates this on a runtime canary probe; locally use
/// `make integration-test`).
///
/// Fixtures MUST live in a non-hidden directory directly under $HOME: /tmp and $TMPDIR are
/// unindexed or reduced-tier. Force-index with mdimport and poll with a timeout — never a
/// fixed sleep — and never assert exact global counts against a live index.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SFIND_INTEGRATION"] == "1"))
struct SpotlightCanaryTests {
    @Test func spotlightIndexesAHomeFixture() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("sfind-itest-canary-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("canary.txt")
        try Data("sfind spotlight canary\n".utf8).write(to: file)

        let importer = Process()
        importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        importer.arguments = [dir.path]
        try importer.run()
        importer.waitUntilExit()

        let deadline = Date().addingTimeInterval(60)
        var found = false
        while Date() < deadline && !found {
            let query = Process()
            let pipe = Pipe()
            query.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            query.arguments = ["-onlyin", dir.path, "kMDItemFSName == \"canary.txt\""]
            query.standardOutput = pipe
            try query.run()
            query.waitUntilExit()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            found = !out.isEmpty
            if !found { Thread.sleep(forTimeInterval: 1) }
        }
        #expect(found, "Spotlight never indexed a fresh $HOME fixture within 60s")
    }
}
