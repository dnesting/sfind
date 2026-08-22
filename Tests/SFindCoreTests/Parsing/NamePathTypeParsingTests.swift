import SFindCore
import Testing

@Suite struct NamePathTypeParsingTests {
    func primary(_ tokens: String...) throws -> Primary {
        guard case .primary(let p)? = try CommandParser().parse(["."] + tokens).expression else {
            Issue.record("expected single primary")
            throw ParseError("test")
        }
        return p
    }

    @Test func nameFamily() throws {
        #expect(try primary("-name", "*.md") == .name("*.md", caseInsensitive: false))
        #expect(try primary("-iname", "*.MD") == .name("*.MD", caseInsensitive: true))
        #expect(try primary("-path", "*/src/*") == .path("*/src/*", caseInsensitive: false))
        #expect(try primary("-ipath", "*/SRC/*") == .path("*/SRC/*", caseInsensitive: true))
        // GNU-compat aliases.
        #expect(try primary("-wholename", "*/x") == .path("*/x", caseInsensitive: false))
        #expect(try primary("-iwholename", "*/x") == .path("*/x", caseInsensitive: true))
        #expect(try primary("-lname", "target*") == .lname("target*", caseInsensitive: false))
        #expect(try primary("-ilname", "TARGET*") == .lname("TARGET*", caseInsensitive: true))
        #expect(try primary("-regex", ".*/f") == .regex(".*/f", caseInsensitive: false))
        #expect(try primary("-iregex", ".*/F") == .regex(".*/F", caseInsensitive: true))
    }

    @Test(arguments: [
        ("b", FileType.block), ("c", .character), ("d", .directory), ("f", .regular),
        ("l", .symlink), ("p", .fifo), ("s", .socket),
        // Undocumented but accepted by macOS find (verified).
        ("w", .whiteout),
    ])
    func typeLetters(_ letter: String, _ type: FileType) throws {
        #expect(try primary("-type", letter) == .type(type))
    }

    @Test(arguments: ["W", "x", "D", "fd", "f,d", ""])
    func rejectsUnknownTypes(_ bad: String) {
        #expect(throws: ParseError.self) { try primary("-type", bad) }
    }

    @Test func ownership() throws {
        #expect(try primary("-user", "david") == .user("david"))
        #expect(try primary("-user", "501") == .user("501"))
        #expect(try primary("-uid", "501") == .user("501"))
        #expect(try primary("-group", "staff") == .group("staff"))
        #expect(try primary("-gid", "20") == .group("20"))
        #expect(try primary("-nouser") == .nouser)
        #expect(try primary("-nogroup") == .nogroup)
    }

    @Test func statPredicates() throws {
        #expect(try primary("-links", "2") == .links(NumericArg(.exactly, 2)))
        #expect(try primary("-inum", "+100") == .inum(NumericArg(.moreThan, 100)))
        #expect(try primary("-samefile", "/etc/hosts") == .samefile("/etc/hosts"))
        #expect(try primary("-empty") == .empty)
        #expect(try primary("-sparse") == .sparse)
        #expect(try primary("-acl") == .acl)
        #expect(try primary("-xattr") == .xattr)
        #expect(
            try primary("-xattrname", "com.apple.quarantine") == .xattrName("com.apple.quarantine"))
        #expect(try primary("-fstype", "apfs") == .fstype("apfs"))
    }

    @Test func gnuAccessExtensions() throws {
        #expect(try primary("-readable") == .readable)
        #expect(try primary("-writable") == .writable)
        #expect(try primary("-executable") == .executable)
    }
}
