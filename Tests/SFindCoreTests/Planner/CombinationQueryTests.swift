import SFindCore
import Testing

@Suite struct CombinationQueryTests {
    @Test func conjunctionCombinesNarrowings() throws {
        #expect(
            try PlannerFixtures.query("-name", "*.md", "-mtime", "-7")
                == "(kMDItemFSName == \"*.md\" && "
                + "kMDItemFSContentChangeDate > $time.iso(2025-12-25T23:59:59Z))")
    }

    @Test func conjunctionIgnoresUnconstrainedTerms() throws {
        #expect(
            try PlannerFixtures.query("-name", "*.md", "-perm", "644")
                == "kMDItemFSName == \"*.md\"")
    }

    @Test func disjunctionOfNarrowings() throws {
        #expect(
            try PlannerFixtures.query("-name", "*.md", "-o", "-name", "*.txt")
                == "(kMDItemFSName == \"*.md\" || kMDItemFSName == \"*.txt\")")
    }

    @Test func disjunctionWithUnconstrainedBranchIsMatchAll() throws {
        // Any branch the index can't express makes the whole OR unconstrained.
        #expect(
            try PlannerFixtures.query("-name", "*.md", "-o", "-perm", "644")
                == QueryPlan.matchAll)
    }

    @Test func negationContributesNoNarrowing() throws {
        // ¬(superset) is not a superset of ¬(exact).
        #expect(try PlannerFixtures.query("!", "-name", "*.md") == QueryPlan.matchAll)
        // ...but siblings still narrow.
        #expect(
            try PlannerFixtures.query("!", "-name", "*.md", "-mtime", "-7")
                == "kMDItemFSContentChangeDate > $time.iso(2025-12-25T23:59:59Z)")
    }

    @Test func impossibleConjunctionSkipsQuery() throws {
        #expect(try PlannerFixtures.plan(["-type", "l", "-name", "*.dylib"]).queryString == nil)
        #expect(try PlannerFixtures.plan(["-false"]).queryString == nil)
    }

    @Test func impossibleBranchDropsFromDisjunction() throws {
        #expect(
            try PlannerFixtures.query("-type", "l", "-o", "-name", "*.md")
                == "kMDItemFSName == \"*.md\"")
    }

    @Test func actionsDoNotConstrain() throws {
        #expect(
            try PlannerFixtures.query("-name", "*.md", "-print0")
                == "kMDItemFSName == \"*.md\"")
        #expect(try PlannerFixtures.query("-print") == QueryPlan.matchAll)
    }

    @Test func emptyExpressionIsMatchAll() throws {
        #expect(try PlannerFixtures.plan([]).queryString == QueryPlan.matchAll)
    }

    @Test func reducedTierRestrictsAttributes() throws {
        // Hidden-directory scopes serve only FSName/uid/gid/dates (verified): size and
        // content-type narrowing must be dropped there, name and date kept.
        #expect(
            try PlannerFixtures.plan(["-type", "d"], reducedTier: true).queryString
                == QueryPlan.matchAll)
        #expect(
            try PlannerFixtures.plan(["-size", "+1k"], reducedTier: true).queryString
                == QueryPlan.matchAll)
        #expect(
            try PlannerFixtures.plan(["-empty"], reducedTier: true).queryString
                == QueryPlan.matchAll)
        #expect(
            try PlannerFixtures.plan(["-name", "*.md"], reducedTier: true).queryString
                == "kMDItemFSName == \"*.md\"")
        #expect(
            try PlannerFixtures.plan(["-user", "david"], reducedTier: true).queryString
                == "kMDItemFSOwnerUserID == 501")
    }

    @Test func warningsCollected() throws {
        let plan = try PlannerFixtures.plan(["-type", "l", "-o", "-lname", "x", "-name", ".b*"])
        #expect(plan.warnings.count == 3)
        let messages = plan.warnings.map(\.message).joined(separator: "\n")
        #expect(messages.contains("symlinks"))
        #expect(messages.contains("-lname"))
        #expect(messages.contains(".b*"))
    }

    @Test func noWarningsForOrdinaryExpressions() throws {
        #expect(try PlannerFixtures.plan(["-name", "*.md", "-type", "f"]).warnings.isEmpty)
    }
}
