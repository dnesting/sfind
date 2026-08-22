import SFindCore
import Testing

@Suite struct ExecParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test func semicolonForm() throws {
        #expect(
            try primary("-exec", "echo", "{}", ";")
                == .exec(
                    .init(
                        argv: ["echo", "{}"], batch: false, fromFileDirectory: false,
                        prompted: false)))
        // {} may appear anywhere, including mid-token (verified find behavior).
        #expect(
            try primary("-exec", "echo", "X{}Y", ";")
                == .exec(
                    .init(
                        argv: ["echo", "X{}Y"], batch: false, fromFileDirectory: false,
                        prompted: false)))
    }

    @Test func batchForm() throws {
        #expect(
            try primary("-exec", "echo", "{}", "+")
                == .exec(
                    .init(
                        argv: ["echo", "{}"], batch: true, fromFileDirectory: false, prompted: false
                    )))
        #expect(
            try primary("-exec", "echo", "prefix", "{}", "+")
                == .exec(
                    .init(
                        argv: ["echo", "prefix", "{}"], batch: true, fromFileDirectory: false,
                        prompted: false)))
    }

    @Test func variants() throws {
        #expect(
            try primary("-execdir", "true", ";")
                == .exec(
                    .init(argv: ["true"], batch: false, fromFileDirectory: true, prompted: false)))
        #expect(
            try primary("-ok", "true", ";")
                == .exec(
                    .init(argv: ["true"], batch: false, fromFileDirectory: false, prompted: true)))
        #expect(
            try primary("-okdir", "true", ";")
                == .exec(
                    .init(argv: ["true"], batch: false, fromFileDirectory: true, prompted: true)))
    }

    /// The batch terminator requires the literal `{}` immediately before `+` (verified:
    /// anything else is "no terminating ';' or '+'"). A `+` elsewhere is an ordinary
    /// argument only when a later valid terminator exists; otherwise the primary is
    /// unterminated.
    @Test func batchTerminatorRules() throws {
        #expect(throws: ParseError.self) { try primary("-exec", "echo", "{}", "foo", "+") }
        #expect(throws: ParseError.self) { try primary("-exec", "echo", "a{}b", "+") }
        #expect(throws: ParseError.self) { try primary("-exec", "echo", "+") }
        // A "+" not preceded by {} is a plain argument if ";" terminates later.
        #expect(
            try primary("-exec", "echo", "+", ";")
                == .exec(
                    .init(
                        argv: ["echo", "+"], batch: false, fromFileDirectory: false, prompted: false
                    )))
    }

    @Test func unterminated() {
        #expect(throws: ParseError.self) { try primary("-exec", "echo") }
        #expect(throws: ParseError.self) { try primary("-exec") }
    }

    @Test func okRejectsBatchForm() {
        // -ok/-okdir accept only the ";" form.
        #expect(throws: ParseError.self) { try primary("-ok", "echo", "{}", "+") }
    }

    @Test func requiresUtilityName() {
        #expect(throws: ParseError.self) { try primary("-exec", ";") }
    }
}
