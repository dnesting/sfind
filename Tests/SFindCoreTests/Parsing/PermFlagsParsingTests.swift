import SFindCore
import Testing

@Suite struct PermFlagsParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test func octalMatchModes() throws {
        #expect(
            try primary("-perm", "644") == .perm(.init(match: .exact, bits: 0o644, source: "644")))
        #expect(
            try primary("-perm", "-644")
                == .perm(.init(match: .allBits, bits: 0o644, source: "-644")))
        // BSD any-bit spelling.
        #expect(
            try primary("-perm", "+222")
                == .perm(.init(match: .anyBits, bits: 0o222, source: "+222")))
        // GNU any-bit spelling, adopted by sfind (macOS find rejects it).
        #expect(
            try primary("-perm", "/222")
                == .perm(.init(match: .anyBits, bits: 0o222, source: "/222")))
    }

    @Test func fullModeBitsParticipate() throws {
        #expect(
            try primary("-perm", "4755")
                == .perm(.init(match: .exact, bits: 0o4755, source: "4755")))
        #expect(
            try primary("-perm", "07777")
                == .perm(.init(match: .exact, bits: 0o7777, source: "07777")))
    }

    @Test func symbolicModes() throws {
        // Symbolic modes start from a zero base with umask disregarded (find semantics).
        #expect(
            try primary("-perm", "u+w") == .perm(.init(match: .exact, bits: 0o200, source: "u+w")))
        #expect(
            try primary("-perm", "-u+w,g+w")
                == .perm(.init(match: .allBits, bits: 0o220, source: "-u+w,g+w")))
        #expect(
            try primary("-perm", "u=rwx")
                == .perm(.init(match: .exact, bits: 0o700, source: "u=rwx")))
    }

    @Test(arguments: ["notamode", "8888", "u+q"])
    func rejectsIllegalModes(_ bad: String) {
        #expect(throws: ParseError.self) { try primary("-perm", bad) }
    }

    @Test func flagsParse() throws {
        guard case .flags(let arg) = try primary("-flags", "-uchg,nouchg") else {
            Issue.record("expected -flags primary")
            return
        }
        #expect(arg.match == .allBits)
        #expect(arg.flags != 0)
        #expect(arg.notflags != 0)
    }

    @Test func flagsMatchModes() throws {
        guard case .flags(let bare) = try primary("-flags", "uchg") else {
            Issue.record("expected -flags primary")
            return
        }
        #expect(bare.match == .exact)
        guard case .flags(let any) = try primary("-flags", "+hidden") else {
            Issue.record("expected -flags primary")
            return
        }
        #expect(any.match == .anyBits)
    }

    @Test func rejectsIllegalFlags() {
        #expect(throws: ParseError.self) { try primary("-flags", "bogusflag") }
    }
}
