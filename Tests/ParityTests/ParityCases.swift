import Foundation
import SFindCore
import Testing

/// Each case is a token list run against /usr/bin/find and against sfind's machinery
/// over the identical walked candidates; sorted outputs and exit statuses must match
/// exactly. `REF` is replaced by the fixture's reference file for -newer forms.
@Suite struct ParityCases {
    static let expressions: [[String]] = [
        // Names and paths.
        ["-name", "*.md"],
        ["-iname", "*.md"],
        ["-name", "*"],
        ["-name", ".*"],
        ["-name", "*.??"],
        ["-name", "[ab].*"],
        ["-name", "[!ab]*"],
        ["-path", "*/src/*"],
        ["-path", "*e*"],
        ["-ipath", "*/SRC/*"],
        ["-lname", "a.md"],
        ["-lname", "missing*"],
        // Regex (BRE default, ERE via -E, anchored whole-path).
        ["-regex", ".*\\.md"],
        ["-regex", ".*/[su][a-z]*\\.swift"],
        ["-E", "-regex", ".*\\.(md|txt)"],
        ["-iregex", ".*upper.*"],
        // Types.
        ["-type", "f"],
        ["-type", "d"],
        ["-type", "l"],
        // Size (block rounding and exact-byte suffixes).
        ["-size", "53"],
        ["-size", "+52"],
        ["-size", "-1"],
        ["-size", "27034c"],
        ["-size", "+1k"],
        ["-size", "0"],
        // Time (floor days, ceil minutes, raw-second suffixes).
        ["-mtime", "-1"],
        ["-mtime", "+0"],
        ["-mtime", "1"],
        ["-mmin", "-60"],
        ["-mmin", "+60"],
        ["-mtime", "-23h30m"],
        ["-newer", "REF"],
        ["!", "-newer", "REF"],
        ["-neweraa", "REF"],
        // Permissions.
        ["-perm", "644"],
        ["-perm", "-644"],
        ["-perm", "+111"],
        ["-perm", "-u+w"],
        ["-perm", "755"],
        // Stat.
        ["-links", "2"],
        ["-empty"],
        ["-type", "f", "-empty"],
        // Operators, precedence, implicit and.
        ["!", "-name", "*.md"],
        ["-not", "-type", "d"],
        ["-name", "*.md", "-size", "+50c"],
        ["-name", "*.md", "-o", "-name", "*.txt"],
        ["(", "-name", "*.md", "-o", "-name", "*.txt", ")", "-size", "+0c"],
        ["-type", "f", "-a", "-name", "*.swift"],
        ["-false", "-o", "-type", "l"],
        ["-true", "-name", "*.log"],
        // Globals.
        ["-maxdepth", "1"],
        ["-maxdepth", "0"],
        ["-mindepth", "2"],
        ["-mindepth", "1", "-maxdepth", "2", "-type", "d"],
        ["-depth", "1"],
        ["-depth", "+2"],
        ["-true", "-o", "-maxdepth", "0"],
        // Symlink modes (file links only: the walk does not follow directory links).
        ["-L", "-type", "l"],
        ["-L", "-type", "f", "-name", "link.md"],
        ["-H", "-type", "l"],
        // Ownership.
        ["-user", NSUserName()],
        ["-nouser"],
        // Implicit-print suppression parity.
        ["-name", "*.md", "-print"],
        ["-name", "*.md", "-print", "-print"],
    ]

    @Test(arguments: expressions.indices)
    func matchesFind(_ index: Int) throws {
        let tree = try ParityTree()
        let tokens = Self.expressions[index].map {
            $0 == "REF" ? tree.referenceFile : $0
        }
        let oracle = try Parity.findOracle(tokens, root: tree.root)
        let ours = try Parity.sfind(tokens, root: tree.root, candidates: tree.candidates())
        #expect(ours.output == oracle.output, "tokens: \(tokens)")
        #expect(ours.status == oracle.status, "status for tokens: \(tokens)")
    }

    @Test func print0Parity() throws {
        let tree = try ParityTree()
        let tokens = ["-name", "*.md", "-print0"]
        let oracle = try Parity.findOracle(tokens, root: tree.root, nulSeparated: true)
        let ours = try Parity.sfind(
            tokens, root: tree.root, candidates: tree.candidates(), nulSeparated: true)
        #expect(ours.output == oracle.output)
    }

    @Test func exprStringMatchesDiscreteTokens() throws {
        let tree = try ParityTree()
        let discrete = try Parity.sfind(
            ["(", "-name", "*.md", "-o", "-name", "*.txt", ")", "-size", "+0c"],
            root: tree.root, candidates: tree.candidates())
        let viaExpr = try Parity.sfind(
            ["--expr", "(-name \"*.md\" -o -name \"*.txt\") -size +0c"],
            root: tree.root, candidates: tree.candidates())
        #expect(viaExpr.output == discrete.output)
        #expect(!viaExpr.output.isEmpty)
    }
}
