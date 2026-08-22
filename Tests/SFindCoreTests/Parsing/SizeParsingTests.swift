import SFindCore
import Testing

@Suite struct SizeParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test func blocksDefault() throws {
        #expect(try primary("-size", "53") == .size(SizeArg(.exactly, 53, .blocks)))
        #expect(try primary("-size", "+52") == .size(SizeArg(.moreThan, 52, .blocks)))
        #expect(try primary("-size", "-54") == .size(SizeArg(.lessThan, 54, .blocks)))
    }

    @Test(arguments: [
        ("c", Int64(1)), ("k", 1 << 10), ("M", 1 << 20), ("G", 1 << 30), ("T", 1 << 40),
        ("P", 1 << 50),
    ])
    func byteSuffixes(_ suffix: String, _ multiplier: Int64) throws {
        #expect(
            try primary("-size", "2\(suffix)")
                == .size(SizeArg(.exactly, 2, .bytes(multiplier: multiplier))))
    }

    // GNU's b and w suffixes are rejected, matching macOS find (verified).
    @Test(arguments: ["1b", "1w", "1B", "1KB", "k", "", "+", "1.5k"])
    func rejectsMalformedSizes(_ bad: String) {
        #expect(throws: ParseError.self) { try primary("-size", bad) }
    }
}
