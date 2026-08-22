import SFindCore
import Testing

/// now is fixed at 2026-01-02T00:00:00Z; bounds carry a ±1s margin absorbing ISO term
/// granularity. Day values use floor(age/86400), minutes ceil(age/60) (both verified).
@Suite struct TimeQueryTests {
    @Test func mtimeWithinDays() throws {
        // -mtime -7: age < 7d  →  t > now-7d (with margin).
        #expect(
            try PlannerFixtures.query("-mtime", "-7")
                == "kMDItemFSContentChangeDate > $time.iso(2025-12-25T23:59:59Z)")
    }

    @Test func mtimeExactDay() throws {
        // -mtime 3 (floor): age ∈ [3d, 4d).
        #expect(
            try PlannerFixtures.query("-mtime", "3")
                == "(kMDItemFSContentChangeDate > $time.iso(2025-12-28T23:59:59Z) && "
                + "kMDItemFSContentChangeDate < $time.iso(2025-12-30T00:00:01Z))")
    }

    @Test func mtimeOlderThanDays() throws {
        // -mtime +2 (floor): age ≥ 3d  →  t ≤ now-3d.
        #expect(
            try PlannerFixtures.query("-mtime", "+2")
                == "kMDItemFSContentChangeDate < $time.iso(2025-12-30T00:00:01Z)")
    }

    @Test func mminUsesCeil() throws {
        // -mmin -90 (ceil): age ≤ 89m  →  t ≥ now-89m.
        #expect(
            try PlannerFixtures.query("-mmin", "-90")
                == "kMDItemFSContentChangeDate > $time.iso(2026-01-01T22:30:59Z)")
    }

    @Test func unitSuffixesAreExactSeconds() throws {
        // -mtime -1h30m: age < 5400s.
        #expect(
            try PlannerFixtures.query("-mtime", "-1h30m")
                == "kMDItemFSContentChangeDate > $time.iso(2026-01-01T22:29:59Z)")
    }

    @Test func birthUsesCreationDate() throws {
        #expect(
            try PlannerFixtures.query("-Btime", "-1")
                == "kMDItemFSCreationDate > $time.iso(2025-12-31T23:59:59Z)")
    }

    @Test func atimeAndCtimeHaveNoAttribute() throws {
        // kMDItemLastUsedDate is not POSIX atime, and ctime has no attribute (verified).
        #expect(try PlannerFixtures.query("-atime", "-7") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-ctime", "-7") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-amin", "-90") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-cmin", "-90") == QueryPlan.matchAll)
    }

    @Test func daystartWidensBounds() throws {
        // With -daystart the day boundary can shift by up to 24h; sfind absorbs it by
        // widening the superset by a day.
        #expect(
            try PlannerFixtures.query("-daystart", "-mtime", "-7")
                == "kMDItemFSContentChangeDate > $time.iso(2025-12-24T23:59:59Z)")
    }

    @Test func newerTranslatesForMtimeAndBirth() throws {
        // Reference resolves to 2026-01-01T00:00:00Z; the bound backs off 1s.
        #expect(
            try PlannerFixtures.query("-newer", "ref")
                == "kMDItemFSContentChangeDate > $time.iso(2025-12-31T23:59:59Z)")
        #expect(
            try PlannerFixtures.query("-newerBm", "ref")
                == "kMDItemFSCreationDate > $time.iso(2025-12-31T23:59:59Z)")
        #expect(
            try PlannerFixtures.query("-newermt", "2026-01-01T00:00:00Z")
                == "kMDItemFSContentChangeDate > $time.iso(2025-12-31T23:59:59Z)")
    }

    @Test func newerOnAtimeCtimeHasNoNarrowing() throws {
        #expect(try PlannerFixtures.query("-anewer", "ref") == QueryPlan.matchAll)
        #expect(try PlannerFixtures.query("-cnewer", "ref") == QueryPlan.matchAll)
    }
}
