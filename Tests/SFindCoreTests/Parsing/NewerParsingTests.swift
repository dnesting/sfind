import SFindCore
import Testing

@Suite struct NewerParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test func classicForms() throws {
        #expect(try primary("-newer", "ref") == .newer(.modify, .file(path: "ref", field: .modify)))
        #expect(
            try primary("-mnewer", "ref") == .newer(.modify, .file(path: "ref", field: .modify)))
        #expect(
            try primary("-anewer", "ref") == .newer(.access, .file(path: "ref", field: .modify)))
        #expect(
            try primary("-cnewer", "ref") == .newer(.change, .file(path: "ref", field: .modify)))
        #expect(try primary("-Bnewer", "ref") == .newer(.birth, .file(path: "ref", field: .modify)))
    }

    static let fields: [(Character, TimeField)] = [
        ("a", .access), ("B", .birth), ("c", .change), ("m", .modify),
    ]

    /// The full 20-form -newerXY matrix (verified: all exist in macOS find).
    @Test func fullMatrix() throws {
        for (xc, x) in Self.fields {
            for (yc, y) in Self.fields {
                #expect(
                    try primary("-newer\(xc)\(yc)", "ref")
                        == .newer(x, .file(path: "ref", field: y)),
                    "-newer\(xc)\(yc)")
            }
            #expect(
                try primary("-newer\(xc)t", "yesterday") == .newer(x, .date("yesterday")),
                "-newer\(xc)t")
        }
    }

    @Test(arguments: ["-newerxx", "-newerta", "-newermq", "-newerm", "-newermmm"])
    func rejectsInvalidCombinations(_ bad: String) {
        #expect(throws: ParseError.self) { try primary(bad, "ref") }
    }
}
