import SFindCore
import Testing

@Suite struct NameQueryTests {
    @Test func starOnlyPatternsTranslateDirectly() throws {
        #expect(try PlannerFixtures.query("-name", "*.md") == "kMDItemFSName == \"*.md\"")
        #expect(try PlannerFixtures.query("-name", "README") == "kMDItemFSName == \"README\"")
        #expect(try PlannerFixtures.query("-name", "*") == "kMDItemFSName == \"*\"")
    }

    @Test func inameAddsCaseModifier() throws {
        #expect(try PlannerFixtures.query("-iname", "*.MD") == "kMDItemFSName == \"*.MD\"c")
    }

    @Test func unsupportedGlobFeaturesWidenToStar() throws {
        // The query language supports only `*` (verified): ? and [...] widen.
        #expect(try PlannerFixtures.query("-name", "a?b") == "kMDItemFSName == \"a*b\"")
        #expect(try PlannerFixtures.query("-name", "[abc].txt") == "kMDItemFSName == \"*.txt\"")
        #expect(try PlannerFixtures.query("-name", "[!x]*") == "kMDItemFSName == \"*\"")
        // Adjacent wildcards collapse.
        #expect(try PlannerFixtures.query("-name", "a**??b") == "kMDItemFSName == \"a*b\"")
        // An unterminated class is a literal bracket (fnmatch behavior).
        #expect(try PlannerFixtures.query("-name", "a[b") == "kMDItemFSName == \"a[b\"")
    }

    @Test func escapesWidenSafely() throws {
        // \* is a literal star in fnmatch; emitting * keeps the superset property.
        #expect(try PlannerFixtures.query("-name", "a\\*b") == "kMDItemFSName == \"a*b\"")
        #expect(try PlannerFixtures.query("-name", "a\\qb") == "kMDItemFSName == \"aqb\"")
    }

    @Test func queryLiteralEscaping() throws {
        #expect(try PlannerFixtures.query("-name", "a\"b") == "kMDItemFSName == \"a\\\"b\"")
    }

    @Test func pathAndRegexContributeNoNarrowing() throws {
        // kMDItemPath is readable but not queryable (verified).
        #expect(try PlannerFixtures.query("-path", "*/src/*") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-regex", ".*/foo") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-lname", "target") == QueryPlan.matchAll)
    }
}
