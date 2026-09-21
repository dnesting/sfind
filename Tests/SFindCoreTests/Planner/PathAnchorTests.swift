import SFindCore
import Testing

@Suite struct PathAnchorTests {
    func fnmatch(_ pattern: String, ci: Bool = false) -> [String] {
        PathAnchor.anchors(fnmatch: pattern, caseInsensitive: ci).map(\.name)
    }

    func regex(_ pattern: String, ci: Bool = false) -> [String] {
        PathAnchor.anchors(regex: pattern, caseInsensitive: ci).map(\.name)
    }

    @Test func fnmatchLiteralRuns() {
        #expect(fnmatch("*/node_modules/*") == ["node_modules"])
        #expect(fnmatch("*/a/b/*") == ["a", "b"])
        #expect(fnmatch("*/a/*/b/*") == ["a", "b"])
        #expect(fnmatch("*/a/*[c]") == ["a"])
    }

    @Test func fnmatchMetacharactersInsideRunDisqualifyIt() {
        #expect(fnmatch("*/x[ab]/*") == [])
        #expect(fnmatch("*/x?y/*") == [])
        #expect(fnmatch("*/x*y/*") == [])
        // A run following a bracket or escape is never derived.
        #expect(fnmatch("*[a]/src/*") == [])
        #expect(fnmatch("*\\*/src/*") == [])
    }

    @Test func fnmatchNeedsBothSlashes() {
        #expect(fnmatch("*/src") == [])
        #expect(fnmatch("src/*") == [])
        #expect(fnmatch("*.md") == [])
        #expect(fnmatch("*//*") == [])
    }

    @Test func fnmatchDeduplicatesAndPreservesOrder() {
        #expect(fnmatch("*/a/*/a/*") == ["a"])
        #expect(fnmatch("*/z/y/*") == ["z", "y"])
    }

    @Test func fnmatchCaseInsensitivity() {
        let anchors = PathAnchor.anchors(fnmatch: "*/Src/*", caseInsensitive: true)
        #expect(anchors == [PathAnchor(name: "Src", caseInsensitive: true)])
        let sensitive = PathAnchor.anchors(fnmatch: "*/Src/*", caseInsensitive: false)
        #expect(sensitive == [PathAnchor(name: "Src", caseInsensitive: false)])
        #expect(anchors != sensitive)
    }

    @Test func regexLiteralRuns() {
        #expect(regex(".*/src/.*") == ["src"])
        #expect(regex(".*/a/b/.*") == ["a", "b"])
        #expect(regex("^.*/src/[^/]*$") == ["src"])
    }

    @Test func regexQuantifiedSlashIsNotAnAnchor() {
        #expect(regex(".*/src/*") == [])
        #expect(regex(".*/src/?x") == [])
        #expect(regex(".*/src/+x") == [])
    }

    @Test func regexGroupingAlternationIntervalDisableDerivation() {
        #expect(regex(".*/(src)/.*") == [])
        #expect(regex(".*/src/.*|.*/lib/.*") == [])
        #expect(regex(".*/src/.{2}") == [])
        #expect(regex(".*/src/\\(x\\)") == [])
    }

    @Test func regexMetacharactersInsideRunDisqualifyIt() {
        #expect(regex(".*/a\\.b/.*") == [])
        #expect(regex(".*/s.c/.*") == [])
        #expect(regex(".*/s[rR]c/.*") == [])
        #expect(regex(".*/s^c/.*") == [])
        // Nothing past a bracket or escape.
        #expect(regex("[a]/src/.*") == [])
        #expect(regex("\\./src/.*") == [])
    }

    @Test func isSatisfiedByRoot() {
        let anchor = PathAnchor(name: "node_modules", caseInsensitive: false)
        #expect(anchor.isSatisfied(byRootTyped: "./x/node_modules"))
        #expect(anchor.isSatisfied(byRootTyped: "/Users/me/node_modules/"))
        #expect(anchor.isSatisfied(byRootTyped: "node_modules"))
        #expect(anchor.isSatisfied(byRootTyped: "/Users/me/node_modules/pkg"))
        #expect(!anchor.isSatisfied(byRootTyped: "."))
        #expect(!anchor.isSatisfied(byRootTyped: "./src"))
        #expect(!anchor.isSatisfied(byRootTyped: "/"))
        #expect(!anchor.isSatisfied(byRootTyped: "/Users/me/node_modules2"))
        #expect(!anchor.isSatisfied(byRootTyped: "my_node_modules"))
    }

    @Test func isSatisfiedCaseInsensitive() {
        let sensitive = PathAnchor(name: "Src", caseInsensitive: false)
        #expect(!sensitive.isSatisfied(byRootTyped: "./src"))
        #expect(sensitive.isSatisfied(byRootTyped: "./Src"))
        let insensitive = PathAnchor(name: "Src", caseInsensitive: true)
        #expect(insensitive.isSatisfied(byRootTyped: "./src"))
        #expect(insensitive.isSatisfied(byRootTyped: "/a/SRC/b"))
    }
}
