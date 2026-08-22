import Foundation
import SFindCore
import Testing

@Suite struct CLITests {
    @Test func helpAndVersion() {
        for flag in ["--help", "-?"] {
            let sink = CollectingSink()
            #expect(SFindCLI.run(arguments: [flag], sink: sink) == 0)
            #expect(sink.text.contains("usage: sfind"))
            #expect(sink.text.contains("--expr"))
        }
        let sink = CollectingSink()
        #expect(SFindCLI.run(arguments: ["--version"], sink: sink) == 0)
        #expect(sink.text.hasPrefix("sfind "))
    }

    @Test func usageErrorPrintsUsage() {
        let sink = CollectingSink()
        #expect(SFindCLI.run(arguments: [], sink: sink) == 1)
        #expect(sink.diagnostics.contains { $0.contains("usage: sfind") })
    }

    @Test func mdfindTranslation() throws {
        let tree = try TempTree()
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: [tree.root, "--mdfind", "-name", "*.md", "-perm", "644"], sink: sink)
        #expect(status == 0)
        #expect(sink.text == "mdfind -onlyin '\(tree.root)' -literal 'kMDItemFSName == \"*.md\"'\n")
        #expect(sink.diagnostics.contains { $0.contains("-perm") && $0.contains("superset") })
    }

    @Test func mdfindFlagPositionIsFlexible() throws {
        let tree = try TempTree()
        let before = CollectingSink()
        #expect(
            SFindCLI.run(arguments: ["--mdfind", tree.root, "-name", "x"], sink: before) == 0)
        let after = CollectingSink()
        #expect(
            SFindCLI.run(arguments: [tree.root, "--mdfind", "-name", "x"], sink: after) == 0)
        #expect(before.text == after.text)
    }

    @Test func mdfindWithImpossibleExpression() throws {
        let tree = try TempTree()
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: [tree.root, "--mdfind", "-type", "l"], sink: sink)
        #expect(status == 1)
        #expect(sink.diagnostics.contains { $0.contains("--mdfind") })
    }

    @Test func scopeWarningOnlyWhenIndexEmpty() throws {
        // A marker-excluded root with no index results explains itself after the fact;
        // predicate-level warnings are the only eager ones.
        let tree = try TempTree()
        try tree.file(".metadata_never_index")
        let sink = CollectingSink()
        _ = SFindCLI.run(arguments: [tree.root, "-name", "*.zzz"], sink: sink)
        #expect(sink.diagnostics.contains { $0.contains("excluded from Spotlight") })

        // Without a marker there is no scope warning even when nothing matches.
        let plain = try TempTree()
        try plain.file("data.sample")
        let quiet = CollectingSink()
        _ = SFindCLI.run(arguments: [plain.root, "-name", "*.zzz"], sink: quiet)
        #expect(!quiet.diagnostics.contains { $0.contains("excluded from Spotlight") })
    }

    @Test func relativeWarningPaths() throws {
        // display() renders marker paths relative to cwd when the root was typed
        // relative, with ".." segments as needed.
        let root = RootScope(typed: ".", followSymlinks: false)
        let cwd = FileManager.default.currentDirectoryPath
        let parent = (cwd as NSString).deletingLastPathComponent
        #expect(SFindCLI.display(parent, like: root) == "..")
        #expect(SFindCLI.display(cwd + "/sub", like: root) == "sub")
        #expect(SFindCLI.display(cwd, like: root) == ".")
        let absolute = RootScope(typed: "/tmp", followSymlinks: false)
        #expect(SFindCLI.display(parent, like: absolute) == parent)
    }
}
