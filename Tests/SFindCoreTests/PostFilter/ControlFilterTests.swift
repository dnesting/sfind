import Foundation
import SFindCore
import Testing

@Suite struct ControlFilterTests {
    @Test func depthGlobals() throws {
        let tree = try TempTree()
        try tree.dir("a")
        try tree.dir("a/b")
        try tree.file("a/b/c")
        #expect(try Filter.relativeMatches(["-maxdepth", "1"], in: tree) == [".", "a"])
        #expect(try Filter.relativeMatches(["-maxdepth", "0"], in: tree) == ["."])
        #expect(
            try Filter.relativeMatches(["-mindepth", "2"], in: tree) == ["a/b", "a/b/c"])
        // Globals apply even from unevaluated branches (verified find behavior).
        #expect(
            try Filter.relativeMatches(["-true", "-o", "-maxdepth", "0"], in: tree) == ["."])
    }

    @Test func depthPrimary() throws {
        let tree = try TempTree()
        try tree.dir("a")
        try tree.file("a/b")
        #expect(try Filter.relativeMatches(["-depth", "1"], in: tree) == ["a"])
        #expect(try Filter.relativeMatches(["-depth", "+0"], in: tree) == ["a", "a/b"])
    }

    @Test func print0EmitsNulTerminators() throws {
        let tree = try TempTree()
        try tree.file("f")
        let (_, text, status, _) = try Filter.run(
            ["-name", "f", "-print0"], root: tree.root, candidates: tree.candidates())
        #expect(text == tree.root + "/f\0")
        #expect(status == 0)
    }

    @Test func quitStopsProcessing() throws {
        let tree = try TempTree()
        try tree.file("a")
        try tree.file("b")
        // -quit does not suppress the implicit -print (verified find behavior); with -s
        // ordering the root prints first, then the first candidate quits before printing.
        let (lines, _, status, _) = try Filter.run(
            ["-s", "-quit"], root: tree.root, candidates: tree.candidates())
        #expect(lines.isEmpty)
        #expect(status == 0)
    }

    @Test func missingCandidateIsDiagnosticAndExitOne() throws {
        let tree = try TempTree()
        try tree.file("real")
        var candidates = tree.candidates()
        candidates.append(Candidate(path: tree.root + "/vanished", depth: 1))
        let (lines, _, status, diagnostics) = try Filter.run(
            ["-name", "*"], root: tree.root, candidates: candidates)
        #expect(lines.count == 2)
        #expect(status == 1)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].contains("vanished"))
    }

    @Test func ignoreReaddirRaceSuppressesMissingErrors() throws {
        let tree = try TempTree()
        try tree.file("real")
        var candidates = tree.candidates()
        candidates.append(Candidate(path: tree.root + "/vanished", depth: 1))
        let (_, _, status, diagnostics) = try Filter.run(
            ["-ignore_readdir_race", "-name", "*"], root: tree.root, candidates: candidates)
        #expect(status == 0)
        #expect(diagnostics.isEmpty)
    }

    @Test func safeOutputSkipsUnsafeNames() throws {
        let tree = try TempTree()
        try tree.file("safe")
        try tree.file("un safe")
        let (lines, _, _, diagnostics) = try Filter.run(
            ["-X", "-type", "f"], root: tree.root, candidates: tree.candidates())
        #expect(lines == [tree.root + "/safe"])
        #expect(diagnostics.count == 1)
    }

    @Test func sortedOutput() throws {
        let tree = try TempTree()
        try tree.file("b")
        try tree.file("a")
        try tree.file("c")
        let (lines, _, _, _) = try Filter.run(
            ["-s", "-type", "f"], root: tree.root, candidates: tree.candidates())
        #expect(lines == [tree.root + "/a", tree.root + "/b", tree.root + "/c"])
    }

    @Test func xdevFiltersOtherDevices() throws {
        let tree = try TempTree()
        try tree.file("here")
        var candidates = tree.candidates()
        // Fabricate a candidate from another device: /dev/null lives on devfs.
        let rootDevice = FileInfo.lstat(tree.root)!.device
        candidates = candidates.map {
            Candidate(path: $0.path, depth: $0.depth, rootDevice: rootDevice)
        }
        candidates.append(Candidate(path: "/dev/null", depth: 1, rootDevice: rootDevice))
        let (with, _, _, _) = try Filter.run(
            ["-xdev", "-name", "null"], root: tree.root, candidates: candidates)
        #expect(with.isEmpty)
        let (without, _, _, _) = try Filter.run(
            ["-name", "null"], root: tree.root, candidates: candidates)
        #expect(without == ["/dev/null"])
    }

    @Test func followActsAsL() throws {
        let tree = try TempTree()
        try tree.dir("realdir")
        try tree.symlink("dirlink", to: "realdir")
        // -follow (deprecated primary) enables -L semantics globally.
        #expect(try Filter.relativeMatches(["-follow", "-type", "l"], in: tree) == [])
        #expect(
            try Filter.relativeMatches(["-type", "d", "-follow"], in: tree)
                == [".", "dirlink", "realdir"])
    }

    @Test func operatorShortCircuitControlsActions() throws {
        let tree = try TempTree()
        try tree.file("x")
        // (-name x -o -name y) -print: only x prints.
        let (lines, _, _, _) = try Filter.run(
            ["(", "-name", "x", "-o", "-name", "y", ")", "-print"],
            root: tree.root, candidates: tree.candidates())
        #expect(lines == [tree.root + "/x"])
        // -name x -print -o -print: matched files print once, others once via the OR arm.
        let (lines2, _, _, _) = try Filter.run(
            ["-type", "f", "(", "-name", "x", "-print", "-o", "-print", ")"],
            root: tree.root, candidates: tree.candidates())
        #expect(lines2 == [tree.root + "/x"])
    }

}
