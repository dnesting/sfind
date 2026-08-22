import Foundation
import SFindCore
import Testing

@Suite struct NamePathFilterTests {
    @Test func nameMatchesLastComponent() throws {
        let tree = try TempTree()
        try tree.file("a.md")
        try tree.file("b.txt")
        try tree.dir("sub")
        try tree.file("sub/c.md")
        #expect(try Filter.relativeMatches(["-name", "*.md"], in: tree) == ["a.md", "sub/c.md"])
    }

    @Test func starMatchesDotfiles() throws {
        // -name '*' matches dotfiles: fnmatch without FNM_PERIOD (verified find behavior).
        let tree = try TempTree()
        try tree.file(".hidden")
        try tree.file("visible")
        #expect(
            try Filter.relativeMatches(["-name", "*"], in: tree) == [".", ".hidden", "visible"])
        #expect(try Filter.relativeMatches(["-name", ".h*"], in: tree) == [".hidden"])
    }

    @Test func caseInsensitiveVariants() throws {
        let tree = try TempTree()
        try tree.file("README.MD")
        #expect(try Filter.relativeMatches(["-name", "*.md"], in: tree) == [])
        #expect(try Filter.relativeMatches(["-iname", "*.md"], in: tree) == ["README.MD"])
    }

    @Test func globClassesAndQuestionMark() throws {
        let tree = try TempTree()
        try tree.file("a1")
        try tree.file("a2")
        try tree.file("b1")
        try tree.file("ab")
        #expect(try Filter.relativeMatches(["-name", "a?"], in: tree) == ["a1", "a2", "ab"])
        #expect(try Filter.relativeMatches(["-name", "[ab]1"], in: tree) == ["a1", "b1"])
        #expect(try Filter.relativeMatches(["-name", "[!a]1"], in: tree) == ["b1"])
    }

    @Test func pathMatchesWholePath() throws {
        let tree = try TempTree()
        try tree.dir("src")
        try tree.file("src/main.swift")
        try tree.file("main.swift")
        // `/` is an ordinary character for -path: `*` crosses separators.
        #expect(
            try Filter.relativeMatches(["-path", "*/src/*"], in: tree) == ["src/main.swift"])
        // A pattern with no leading * cannot match the constructed path (verified).
        #expect(try Filter.relativeMatches(["-path", "main.swift"], in: tree) == [])
    }

    @Test func regexAnchorsWholePath() throws {
        let tree = try TempTree()
        try tree.file("find.txt")
        // Verified find behavior: whole path must match entirely.
        #expect(try Filter.relativeMatches(["-regex", "find.txt"], in: tree) == [])
        #expect(try Filter.relativeMatches(["-regex", ".*/find\\.txt"], in: tree) == ["find.txt"])
        #expect(try Filter.relativeMatches(["-regex", ".*find.*"], in: tree) == ["find.txt"])
    }

    @Test func regexDialects() throws {
        let tree = try TempTree()
        try tree.file("ab")
        try tree.file("aab")
        // BRE: a\{2\} needs escaped braces; unescaped braces are literal.
        #expect(try Filter.relativeMatches(["-regex", ".*a\\{2\\}b"], in: tree) == ["aab"])
        // -E selects ERE.
        #expect(try Filter.relativeMatches(["-E", "-regex", ".*a{2}b"], in: tree) == ["aab"])
        // GNU -regextype overrides.
        #expect(
            try Filter.relativeMatches(
                ["-regextype", "posix-extended", "-regex", ".*(aa|zz)b"], in: tree) == ["aab"])
    }

    @Test func lnameMatchesLinkTarget() throws {
        let tree = try TempTree()
        try tree.file("target.dat")
        try tree.symlink("link", to: "target.dat")
        #expect(try Filter.relativeMatches(["-lname", "target*"], in: tree) == ["link"])
        #expect(try Filter.relativeMatches(["-ilname", "TARGET*"], in: tree) == ["link"])
        // Under -L the link resolves, so -lname no longer sees it (matches find).
        #expect(try Filter.relativeMatches(["-L", "-lname", "target*"], in: tree) == [])
    }
}
