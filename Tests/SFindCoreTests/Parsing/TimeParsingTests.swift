import SFindCore
import Testing

@Suite struct TimeParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test(arguments: [
        ("-atime", TimeField.access), ("-ctime", .change), ("-mtime", .modify),
        ("-Btime", .birth),
    ])
    func dayGranularity(_ name: String, _ field: TimeField) throws {
        #expect(try primary(name, "3") == .time(field, TimeArg(.exactly, .days(3))))
        #expect(try primary(name, "+3") == .time(field, TimeArg(.moreThan, .days(3))))
        #expect(try primary(name, "-3") == .time(field, TimeArg(.lessThan, .days(3))))
    }

    @Test(arguments: [
        ("-amin", TimeField.access), ("-cmin", .change), ("-mmin", .modify),
        ("-Bmin", .birth),
    ])
    func minuteGranularity(_ name: String, _ field: TimeField) throws {
        #expect(try primary(name, "-90") == .time(field, TimeArg(.lessThan, .minutes(90))))
    }

    @Test func unitSuffixesAreRawSeconds() throws {
        #expect(try primary("-mtime", "1s") == .time(.modify, TimeArg(.exactly, .seconds(1))))
        #expect(try primary("-mtime", "2m") == .time(.modify, TimeArg(.exactly, .seconds(120))))
        #expect(try primary("-mtime", "3h") == .time(.modify, TimeArg(.exactly, .seconds(10800))))
        #expect(try primary("-mtime", "1d") == .time(.modify, TimeArg(.exactly, .seconds(86400))))
        #expect(try primary("-mtime", "1w") == .time(.modify, TimeArg(.exactly, .seconds(604_800))))
        // Terms combine: -1h30m = within the last 5400 seconds.
        #expect(
            try primary("-atime", "-1h30m") == .time(.access, TimeArg(.lessThan, .seconds(5400))))
    }

    @Test(arguments: ["x", "1x", "1h30", "h", "", "+", "1h30mx"])
    func rejectsMalformedTimeValues(_ bad: String) {
        #expect(throws: ParseError.self) { try primary("-mtime", bad) }
    }

    @Test func requiresArgument() {
        #expect(throws: ParseError("-mtime: requires additional arguments")) {
            try primary("-mtime")
        }
    }
}
