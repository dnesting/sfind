import SFindCore
import Testing

/// Plan-level behavior of the -content primary and of the path anchors the planner
/// derives from top-level -path/-regex conjuncts.
@Suite struct ContentQueryTests {
    @Test func contentQueryOneClausePerWord() {
        #expect(Planner.contentQuery("zebra") == "kMDItemTextContent == \"zebra\"cd")
        #expect(
            Planner.contentQuery("zebra fish")
                == "(kMDItemTextContent == \"zebra\"cd && kMDItemTextContent == \"fish\"cd)")
        #expect(
            Planner.contentQuery("  zebra\tfish ")
                == "(kMDItemTextContent == \"zebra\"cd && kMDItemTextContent == \"fish\"cd)")
        #expect(Planner.contentQuery("zebra*") == "kMDItemTextContent == \"zebra*\"cd")
    }

    @Test func contentQueryEscapesQuotesAndBackslashes() {
        #expect(Planner.contentQuery("a\"b") == "kMDItemTextContent == \"a\\\"b\"cd")
        #expect(Planner.contentQuery("a\\b") == "kMDItemTextContent == \"a\\\\b\"cd")
    }

    @Test func topLevelContentIsSatisfiedByIndex() throws {
        let plan = try PlannerFixtures.plan(["-content", "zebra"])
        #expect(plan.queryString == Planner.contentQuery("zebra"))
        #expect(plan.contentSatisfiedByIndex == ["zebra"])
        #expect(plan.contentNeedingMembership.isEmpty)
        #expect(!plan.isMatchAll)
    }

    @Test func multiWordContentNarrowsWithEveryWord() throws {
        let plan = try PlannerFixtures.plan(["-content", "zebra fish"])
        #expect(plan.queryString == Planner.contentQuery("zebra fish"))
        #expect(plan.contentSatisfiedByIndex == ["zebra fish"])
    }

    @Test func contentConjoinedWithOtherNarrowing() throws {
        let plan = try PlannerFixtures.plan(["-name", "*.md", "-content", "zebra"])
        let query = try #require(plan.queryString)
        #expect(query.contains("kMDItemFSName == \"*.md\""))
        #expect(query.contains(Planner.contentQuery("zebra")))
        #expect(plan.contentSatisfiedByIndex == ["zebra"])
        #expect(plan.contentNeedingMembership.isEmpty)
    }

    @Test func nestedConjunctionsAreTopLevel() throws {
        let plan = try PlannerFixtures.plan([
            "(", "-content", "zebra", "-name", "x", ")", "-content", "fish",
        ])
        #expect(plan.contentSatisfiedByIndex == ["zebra", "fish"])
        #expect(plan.contentNeedingMembership.isEmpty)
    }

    @Test func negatedContentNeedsMembership() throws {
        let plan = try PlannerFixtures.plan(["!", "-content", "zebra"])
        #expect(plan.isMatchAll)
        #expect(plan.contentSatisfiedByIndex.isEmpty)
        #expect(plan.contentNeedingMembership == ["zebra"])
    }

    @Test func contentUnderDisjunctionNeedsMembership() throws {
        let plan = try PlannerFixtures.plan([
            "(", "-content", "zebra", "-o", "-name", "other.txt", ")",
        ])
        let query = try #require(plan.queryString)
        #expect(query.contains(Planner.contentQuery("zebra")))
        #expect(query.contains("kMDItemFSName == \"other.txt\""))
        #expect(plan.contentSatisfiedByIndex.isEmpty)
        #expect(plan.contentNeedingMembership == ["zebra"])
    }

    @Test func membershipTermsKeepExpressionOrderWithoutDuplicates() throws {
        let plan = try PlannerFixtures.plan([
            "-content", "zebra", "-o", "-content", "fish", "-o", "-content", "zebra",
        ])
        #expect(plan.contentNeedingMembership == ["zebra", "fish"])
    }

    @Test func mixedTopLevelAndNestedContent() throws {
        let plan = try PlannerFixtures.plan([
            "-content", "zebra", "(", "-content", "fish", "-o", "-name", "x", ")",
        ])
        #expect(plan.contentSatisfiedByIndex == ["zebra"])
        #expect(plan.contentNeedingMembership == ["fish"])
    }

    @Test func reducedTierContentContributesNoNarrowing() throws {
        let plan = try PlannerFixtures.plan(["-content", "zebra"], reducedTier: true)
        #expect(plan.isMatchAll)
        #expect(plan.contentSatisfiedByIndex.isEmpty)
        #expect(plan.contentNeedingMembership == ["zebra"])
    }

    @Test func impossibleQueryLeavesContentToMembership() throws {
        let plan = try PlannerFixtures.plan(["-content", "zebra", "-type", "l"])
        #expect(plan.queryString == nil)
        #expect(plan.contentSatisfiedByIndex.isEmpty)
        #expect(plan.contentNeedingMembership == ["zebra"])
    }

    @Test func noContentTerms() throws {
        let plan = try PlannerFixtures.plan(["-name", "x"])
        #expect(plan.contentSatisfiedByIndex.isEmpty)
        #expect(plan.contentNeedingMembership.isEmpty)
    }

    // MARK: - Anchors

    @Test func anchorsFromTopLevelPathConjuncts() throws {
        #expect(
            try PlannerFixtures.plan(["-path", "*/node_modules/*", "-type", "f"]).anchors
                == [PathAnchor(name: "node_modules", caseInsensitive: false)])
        #expect(
            try PlannerFixtures.plan(["-ipath", "*/SRC/*"]).anchors
                == [PathAnchor(name: "SRC", caseInsensitive: true)])
        #expect(
            try PlannerFixtures.plan(["-regex", ".*/src/.*"]).anchors
                == [PathAnchor(name: "src", caseInsensitive: false)])
        #expect(
            try PlannerFixtures.plan(["-iregex", ".*/src/.*"]).anchors
                == [PathAnchor(name: "src", caseInsensitive: true)])
    }

    @Test func anchorsAccumulateAcrossConjunctsInOrder() throws {
        #expect(
            try PlannerFixtures.plan(["-path", "*/a/*", "-path", "*/b/*"]).anchors.map(\.name)
                == ["a", "b"])
        #expect(
            try PlannerFixtures.plan(["(", "-path", "*/a/*", "-path", "*/b/*", ")"]).anchors
                .map(\.name) == ["a", "b"])
        // The same anchor from two conjuncts appears once.
        #expect(
            try PlannerFixtures.plan(["-path", "*/a/*", "-regex", ".*/a/.*"]).anchors.map(\.name)
                == ["a"])
        // Case sensitivity distinguishes anchors.
        #expect(
            try PlannerFixtures.plan(["-path", "*/a/*", "-ipath", "*/a/*"]).anchors.count == 2)
    }

    @Test func anchorsIgnoreNegatedAndDisjoinedTerms() throws {
        #expect(try PlannerFixtures.plan(["!", "-path", "*/x/*"]).anchors.isEmpty)
        #expect(try PlannerFixtures.plan(["-not", "-path", "*/x/*"]).anchors.isEmpty)
        #expect(
            try PlannerFixtures.plan(["-path", "*/a/*", "-o", "-path", "*/b/*"]).anchors.isEmpty)
        #expect(
            try PlannerFixtures.plan(["-type", "f", "(", "-path", "*/a/*", "-o", "-name", "x", ")"])
                .anchors.isEmpty)
        // A top-level anchor survives beside a disjunction.
        #expect(
            try PlannerFixtures.plan([
                "-path", "*/a/*", "(", "-path", "*/b/*", "-o", "-name", "x", ")",
            ]).anchors.map(\.name) == ["a"])
    }

    @Test func anchorsAbsentWhenPatternHasNone() throws {
        #expect(try PlannerFixtures.plan(["-path", "*/x[ab]/*"]).anchors.isEmpty)
        #expect(try PlannerFixtures.plan(["-path", "*.md"]).anchors.isEmpty)
        #expect(try PlannerFixtures.plan(["-name", "src"]).anchors.isEmpty)
        #expect(try PlannerFixtures.plan([]).anchors.isEmpty)
    }

    @Test func isMatchAll() throws {
        #expect(try PlannerFixtures.plan([]).isMatchAll)
        #expect(try PlannerFixtures.plan(["-path", "*/x/*"]).isMatchAll)
        #expect(try PlannerFixtures.plan(["-perm", "644"]).isMatchAll)
        #expect(!(try PlannerFixtures.plan(["-name", "x"]).isMatchAll))
        #expect(!(try PlannerFixtures.plan(["-type", "l"]).isMatchAll))
        #expect(!(try PlannerFixtures.plan(["-content", "x"]).isMatchAll))
    }
}
