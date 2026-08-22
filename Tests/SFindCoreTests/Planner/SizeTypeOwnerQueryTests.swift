import SFindCore
import Testing

@Suite struct SizeTypeOwnerQueryTests {
    @Test func sizeBlocksRoundingRange() throws {
        // -size 53 (512-byte blocks, st_size rounded up): size ∈ (26624, 27136].
        // Directories pass through: their FSSize is not reliably st_size.
        #expect(
            try PlannerFixtures.query("-size", "53")
                == "((kMDItemFSSize > 26624 && kMDItemFSSize <= 27136) || "
                + "kMDItemContentTypeTree == \"public.folder\")")
        #expect(
            try PlannerFixtures.query("-size", "+53")
                == "(kMDItemFSSize > 27136 || kMDItemContentTypeTree == \"public.folder\")")
        #expect(
            try PlannerFixtures.query("-size", "-53")
                == "(kMDItemFSSize <= 26624 || kMDItemContentTypeTree == \"public.folder\")")
    }

    @Test func sizeByteSuffixesAreExact() throws {
        // Scaled suffixes compare exact bytes with no rounding (verified macOS
        // behavior, differs from GNU).
        #expect(
            try PlannerFixtures.query("-size", "27034c")
                == "(kMDItemFSSize == 27034 || kMDItemContentTypeTree == \"public.folder\")")
        #expect(
            try PlannerFixtures.query("-size", "+26k")
                == "(kMDItemFSSize > 26624 || kMDItemContentTypeTree == \"public.folder\")")
    }

    @Test func emptyMatchesZeroFilesAndFolders() throws {
        #expect(
            try PlannerFixtures.query("-empty")
                == "(kMDItemFSSize == 0 || kMDItemContentTypeTree == \"public.folder\")")
    }

    @Test func typeDirectoryNarrows() throws {
        #expect(
            try PlannerFixtures.query("-type", "d") == "kMDItemContentTypeTree == \"public.folder\""
        )
    }

    @Test func typeRegularCannotNarrowSoundly() throws {
        // != "public.folder" would drop items missing the attribute.
        #expect(try PlannerFixtures.query("-type", "f") == QueryPlan.matchAll)
    }

    @Test(arguments: ["l", "s", "p", "b", "c", "w"])
    func unindexedTypesAreImpossible(_ letter: String) throws {
        // Symlinks, sockets, FIFOs, devices, whiteouts: not in the index at all.
        let plan = try PlannerFixtures.plan(["-type", letter])
        #expect(plan.queryString == nil)
        #expect(!plan.warnings.isEmpty)
    }

    @Test func ownershipResolvesToIDs() throws {
        #expect(try PlannerFixtures.query("-user", "david") == "kMDItemFSOwnerUserID == 501")
        #expect(try PlannerFixtures.query("-user", "777") == "kMDItemFSOwnerUserID == 777")
        #expect(try PlannerFixtures.query("-group", "staff") == "kMDItemFSOwnerGroupID == 20")
    }

    @Test func unknownUserThrows() {
        #expect(throws: ParseError.self) { try PlannerFixtures.query("-user", "nobody-here") }
    }

    @Test func postOnlyPredicatesContributeNothing() throws {
        for tokens in [
            ["-perm", "644"], ["-links", "2"], ["-inum", "5"], ["-flags", "uchg"],
            ["-acl"], ["-xattr"], ["-xattrname", "x"], ["-fstype", "apfs"], ["-sparse"],
            ["-samefile", "/etc/hosts"], ["-nouser"], ["-nogroup"], ["-readable"],
            ["-writable"], ["-executable"], ["-depth", "2"],
        ] {
            #expect(try PlannerFixtures.plan(tokens).queryString == QueryPlan.matchAll, "\(tokens)")
        }
    }
}
