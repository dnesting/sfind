import Foundation
import SFindCore
import Testing

@Suite struct DebugTests {
    @Test func flagParsesAnywhere() throws {
        #expect(try CommandParser().parse(["--debug", "."]).options.debug)
        #expect(try CommandParser().parse([".", "--debug", "-name", "x"]).options.debug)
        #expect(!(try CommandParser().parse(["."]).options.debug))
    }

    @Test func indexOnlyRunExplainsQueryAndResults() throws {
        let tree = try TempTree()
        try tree.file("a.md")
        let sink = CollectingSink()
        let status = SFindCLI.run(arguments: [tree.root, "--debug", "-name", "*.md"], sink: sink)
        #expect(status == 0)
        let debug = sink.diagnostics.filter { $0.hasPrefix("debug: ") }
        #expect(debug.contains { $0.hasPrefix("debug: root '\(tree.root)': ") })
        #expect(
            debug.contains { $0 == "debug: planned spotlight query: kMDItemFSName == \"*.md\"" })
        #expect(debug.contains { $0 == "debug: walk mode: off" })
        #expect(debug.contains { $0.hasPrefix("debug: spotlight scope: ") })
        // $TMPDIR is served by the reduced index tier, so the result count is not
        // asserted; the summary lines must be present in either case.
        #expect(
            debug.contains {
                $0.hasPrefix("debug: spotlight results: ") && $0.contains(" returned, ")
                    && $0.contains(" delivered to the post-filter")
            })
        #expect(
            debug.contains {
                $0.hasPrefix("debug: post-filter: ") && $0.contains(" from the index, ")
                    && $0.contains(" matched; exit status 0; ")
            })
        // Regular output is unaffected by the flag.
        #expect(sink.lines.allSatisfy { $0 == tree.root + "/a.md" })
    }

    @Test func walkRunExplainsPhases() throws {
        let tree = try TempTree()
        try tree.file("a.md")
        try tree.dir(".hidden")
        try tree.file(".hidden/b.md")
        let sink = CollectingSink()
        let status = SFindCLI.run(
            arguments: [tree.root, "--debug", "--walk", "-name", "*.md"], sink: sink)
        #expect(status == 0)
        let debug = sink.diagnostics.filter { $0.hasPrefix("debug: ") }
        #expect(debug.contains { $0 == "debug: walk mode: gaps" })
        #expect(
            debug.contains {
                $0.hasPrefix("debug: walk mode gaps: exhaustive walk of 1 root first")
            })
        #expect(
            debug.contains {
                $0.hasPrefix("debug: exhaustive walk: scanned 3 entries, yielded 4 candidates")
                    && $0.hasSuffix("scope exhausted, index not needed")
            })
        #expect(
            debug.contains {
                $0.hasPrefix("debug: post-filter: 4 candidates (0 from the index, 4 from the walk")
                    && $0.contains("2 rejected, 2 matched")
            })
        #expect(sink.lines.sorted() == [tree.root + "/.hidden/b.md", tree.root + "/a.md"])
    }

    @Test func postFilterOnlyTermsAndAnchorsAreListed() throws {
        let tree = try TempTree()
        let sink = CollectingSink()
        _ = SFindCLI.run(
            arguments: [tree.root, "--debug", "-path", "*/src/*", "-perm", "644"], sink: sink)
        let debug = sink.diagnostics.filter { $0.hasPrefix("debug: ") }
        #expect(
            debug.contains {
                $0 == "debug: the query narrows nothing: the index returns the whole scope"
            })
        #expect(debug.contains { $0 == "debug: post-filter only: -path */src/*, -perm" })
        #expect(debug.contains { $0 == "debug: path anchors: src" })
        // The anchor refinement runs (match-all query) and finds nothing indexed.
        #expect(
            debug.contains {
                $0.hasPrefix("debug: path anchor 'src': ") && $0.contains("0 directories")
            })
    }

    @Test func noDebugLinesWithoutTheFlag() throws {
        let tree = try TempTree()
        let sink = CollectingSink()
        _ = SFindCLI.run(arguments: [tree.root, "-name", "x"], sink: sink)
        #expect(!sink.diagnostics.contains { $0.hasPrefix("debug: ") })
    }
}
