import Darwin
import Foundation
import SFindCore
import Testing

@Suite struct LsActionTests {
    /// The strongest possible check: -ls output must be byte-identical to
    /// /usr/bin/find -ls for the same files.
    @Test func lsMatchesFindByteForByte() throws {
        let tree = try TempTree()
        try tree.file("plain", size: 1234, mode: 0o644)
        try tree.file(
            "old", size: 7,
            mtime: Date().addingTimeInterval(-400 * 86400))
        try tree.dir("dir")
        try tree.symlink("link", to: "plain")

        let oracle = Process()
        let pipe = Pipe()
        oracle.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        oracle.arguments = [tree.root, "-ls"]
        oracle.standardOutput = pipe
        try oracle.run()
        let expected = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "\n").map(String.init).sorted()
        oracle.waitUntilExit()

        let (lines, _, status, _) = try Filter.run(
            ["-ls"], root: tree.root, candidates: tree.candidates())
        #expect(lines.sorted() == expected)
        #expect(status == 0)
    }
}

@Suite struct ExecActionTests {
    @Test func execAsPredicateFilters() throws {
        let tree = try TempTree()
        try tree.file("f")
        try tree.dir("d")
        // `test -f {}` is true only for the regular file.
        #expect(
            try Filter.relativeMatches(
                ["-mindepth", "1", "-exec", "test", "-f", "{}", ";", "-print"], in: tree) == ["f"])
        // Substitution works mid-token.
        #expect(
            try Filter.relativeMatches(
                ["-mindepth", "1", "-exec", "test", "-f", "{}", ";", "-name", "f", "-print"],
                in: tree)
                == ["f"])
    }

    @Test func execFalseKeepsExitZero() throws {
        let tree = try TempTree()
        try tree.file("f")
        // `;` form: a failing child only makes the predicate false.
        let (lines, _, status, _) = try Filter.run(
            ["-exec", "false", ";", "-print"], root: tree.root, candidates: tree.candidates())
        #expect(lines.isEmpty)
        #expect(status == 0)
    }

    @Test func execBatchAlwaysTrueButPoisonsExitStatus() throws {
        let tree = try TempTree()
        try tree.file("f")
        // Batch form is always true (everything prints), but a nonzero child makes
        // the overall exit status 1 (verified find behavior).
        let (lines, _, status, _) = try Filter.run(
            ["-type", "f", "-exec", "false", "{}", "+", "-print"],
            root: tree.root, candidates: tree.candidates())
        #expect(lines.count == 1)
        #expect(status == 1)

        let (_, _, okStatus, _) = try Filter.run(
            ["-type", "f", "-exec", "true", "{}", "+", "-print"],
            root: tree.root, candidates: tree.candidates())
        #expect(okStatus == 0)
    }

    @Test func execBatchSideEffect() throws {
        let tree = try TempTree()
        try tree.file("a.dat")
        try tree.file("b.dat")
        let log = tree.root + "/log.txt"
        // sh -c writes all batched paths to a file in one invocation.
        _ = try Filter.run(
            ["-name", "*.dat", "-exec", "/bin/sh", "-c", "echo \"$@\" > \(log)", "sh", "{}", "+"],
            root: tree.root, candidates: tree.candidates())
        let content = try String(contentsOfFile: log, encoding: .utf8)
        #expect(content.contains("a.dat"))
        #expect(content.contains("b.dat"))
    }

    @Test func execdirRunsFromFileDirectory() throws {
        let tree = try TempTree()
        try tree.dir("sub")
        try tree.file("sub/target")
        // `test -f {}` with the unqualified name only succeeds when run from sub/.
        #expect(
            try Filter.relativeMatches(
                ["-type", "f", "-execdir", "test", "-f", "{}", ";", "-print"], in: tree)
                == ["sub/target"])
    }

    @Test func okPromptGates() throws {
        let tree = try TempTree()
        try tree.file("f")
        var prompts: [String] = []
        let (linesYes, _, _, _) = try Filter.run(
            ["-type", "f", "-ok", "true", ";", "-print"], root: tree.root,
            candidates: tree.candidates(),
            promptResponder: { prompt in
                prompts.append(prompt)
                return true
            })
        #expect(linesYes.count == 1)
        #expect(prompts == ["\"true\""])

        let (linesNo, _, statusNo, _) = try Filter.run(
            ["-type", "f", "-ok", "true", ";", "-print"], root: tree.root,
            candidates: tree.candidates(), promptResponder: { _ in false })
        #expect(linesNo.isEmpty)
        #expect(statusNo == 0)
    }
}

@Suite struct DeleteActionTests {
    @Test func deleteByPattern() throws {
        let tree = try TempTree()
        try tree.file("keep.txt")
        try tree.file("junk.tmp")
        try tree.dir("sub")
        try tree.file("sub/other.tmp")
        let (_, _, status, diags) = try Filter.run(
            ["-name", "*.tmp", "-delete"], root: tree.root, candidates: tree.candidates())
        #expect(status == 0)
        #expect(diags.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tree.root + "/junk.tmp"))
        #expect(!FileManager.default.fileExists(atPath: tree.root + "/sub/other.tmp"))
        #expect(FileManager.default.fileExists(atPath: tree.root + "/keep.txt"))
    }

    @Test func deleteWholeTreeChildrenFirst() throws {
        let tree = try TempTree()
        try tree.dir("a/b/c")
        try tree.file("a/b/c/deep.txt")
        try tree.file("a/top.txt")
        let (_, _, status, diags) = try Filter.run(
            ["-delete"], root: tree.root, candidates: tree.candidates())
        #expect(status == 0)
        #expect(diags.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tree.root))
    }

    @Test func deleteNonEmptyDirectoryFails() throws {
        let tree = try TempTree()
        try tree.dir("sub")
        try tree.file("sub/x")
        let (_, _, status, diags) = try Filter.run(
            ["-type", "d", "-name", "sub", "-delete"],
            root: tree.root, candidates: tree.candidates())
        #expect(status == 1)
        #expect(diags.first?.contains("-delete") == true)
        #expect(FileManager.default.fileExists(atPath: tree.root + "/sub/x"))
    }

    @Test func deleteForbiddenWithSymlinkFollowing() throws {
        let tree = try TempTree()
        try tree.file("f")
        let (_, _, status, diags) = try Filter.run(
            ["-L", "-name", "f", "-delete"], root: tree.root, candidates: tree.candidates())
        #expect(status == 1)
        #expect(diags.first?.contains("forbidden") == true)
        #expect(FileManager.default.fileExists(atPath: tree.root + "/f"))
    }
}

@Suite struct PrintfActionTests {
    @Test func commonDirectives() throws {
        let tree = try TempTree()
        try tree.file("sub-a", size: 42, mode: 0o644)
        try tree.dir("d")
        let text = { (fmt: String, extra: [String]) in
            try Filter.run(
                ["-name", "sub-a"] + extra + ["-printf", fmt],
                root: tree.root, candidates: tree.candidates()
            ).text
        }
        #expect(try text("%f\\n", []) == "sub-a\n")
        #expect(try text("%p|%P|%d\\n", []) == "\(tree.root)/sub-a|sub-a|1\n")
        #expect(try text("%H\\n", []) == "\(tree.root)\n")
        #expect(try text("%h\\n", []) == "\(tree.root)\n")
        #expect(try text("%s %m %y %n\\n", []) == "42 644 f 1\n")
        #expect(try text("%M\\n", []) == "-rw-r--r--\n")
        #expect(try text("[%10s]\\n", []) == "[        42]\n")
        #expect(try text("[%-10f]\\n", []) == "[sub-a     ]\n")
        #expect(try text("%%|\\t|\\\\\\n", []) == "%|\t|\\\n")
    }

    @Test func timeDirectives() throws {
        let tree = try TempTree()
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        try tree.file("f", mtime: mtime)
        let (_, text, _, _) = try Filter.run(
            ["-name", "f", "-printf", "%T@\\n"],
            root: tree.root, candidates: tree.candidates())
        #expect(text.hasPrefix("1600000000."))
        let (_, year, _, _) = try Filter.run(
            ["-name", "f", "-printf", "%TY\\n"],
            root: tree.root, candidates: tree.candidates())
        #expect(year == "2020\n")
    }

    @Test func unknownDirectiveWarnsOnce() throws {
        let tree = try TempTree()
        try tree.file("a")
        try tree.file("b")
        let (_, _, _, diags) = try Filter.run(
            ["-type", "f", "-printf", "%q\\n"],
            root: tree.root, candidates: tree.candidates())
        #expect(diags.count == 1)
    }
}

@Suite struct PruneTests {
    @Test func pruneExcludesSubtree() throws {
        let tree = try TempTree()
        try tree.dir("src")
        try tree.file("src/main.swift")
        try tree.dir("docs")
        try tree.file("docs/readme.md")
        // Classic idiom: skip src entirely. -prune is true so the OR short-circuits
        // (src itself is not printed), and src's descendants are never visited.
        #expect(
            try Filter.relativeMatches(
                ["-name", "src", "-prune", "-o", "-print"], in: tree)
                == [".", "docs", "docs/readme.md"])
        // With an explicit -print after -prune, the pruned dir itself prints but its
        // contents still do not.
        #expect(
            try Filter.relativeMatches(
                ["-name", "src", "-prune", "-print", "-o", "-print"], in: tree)
                == [".", "docs", "docs/readme.md", "src"])
    }

    @Test func pruneInertUnderDepthFirst() throws {
        let tree = try TempTree()
        try tree.dir("src")
        try tree.file("src/main.swift")
        let (lines, _, _, _) = try Filter.run(
            ["-d", "-name", "src", "-prune", "-o", "-print"],
            root: tree.root, candidates: tree.candidates())
        // With -d, -prune has no effect: src/main.swift still prints.
        #expect(lines.contains(tree.root + "/src/main.swift"))
    }
}
