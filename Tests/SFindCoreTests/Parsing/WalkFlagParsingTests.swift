import SFindCore
import Testing

@Suite struct WalkFlagParsingTests {
    func parse(_ args: [String]) throws -> ParsedCommand {
        try CommandParser().parse(args)
    }

    @Test func defaults() throws {
        let cmd = try parse(["."])
        #expect(cmd.options.walk == .off)
        #expect(!cmd.options.progress)
    }

    @Test func walkModes() throws {
        #expect(try parse(["--walk", "."]).options.walk == .gaps)
        #expect(try parse(["--walk=gaps", "."]).options.walk == .gaps)
        #expect(try parse(["--walk=only", "."]).options.walk == .only)
        #expect(try parse(["--walk=off", "."]).options.walk == .off)
        // Last one wins.
        #expect(try parse(["--walk=only", "--walk=off", "."]).options.walk == .off)
        #expect(try parse(["--walk=off", "--walk", "."]).options.walk == .gaps)
    }

    @Test func walkModeValueIsValidated() {
        #expect(throws: ParseError.self) { try parse(["--walk=bogus", "."]) }
        #expect(throws: ParseError.self) { try parse(["--walk=", "."]) }
        #expect(throws: ParseError.self) { try parse(["--walk=GAPS", "."]) }
        #expect(throws: ParseError.self) { try parse([".", "--walk=all"]) }
    }

    @Test func progressFlag() throws {
        #expect(try parse(["--progress", "."]).options.progress)
        #expect(try parse([".", "--progress"]).options.progress)
        #expect(try parse([".", "-name", "x", "--progress"]).options.progress)
    }

    @Test func flagsAcceptedBeforeAndAfterPaths() throws {
        let before = try parse(["--walk=only", "--progress", "/a", "/b", "-name", "x"])
        let after = try parse(["/a", "/b", "--walk=only", "-name", "x", "--progress"])
        let split = try parse(["--progress", "/a", "/b", "-name", "x", "--walk=only"])
        for cmd in [before, after, split] {
            #expect(cmd.options.walk == .only)
            #expect(cmd.options.progress)
            #expect(cmd.paths == ["/a", "/b"])
            #expect(cmd.expression == .primary(.name("x", caseInsensitive: false)))
        }
    }

    @Test func flagsCombineWithShortOptionsAndMdfind() throws {
        let cmd = try parse(["-L", "--walk", "-s", ".", "--mdfind"])
        #expect(cmd.options.symlinks == .always)
        #expect(cmd.options.sorted)
        #expect(cmd.options.walk == .gaps)
        #expect(cmd.options.translateOnly)
    }

    @Test func flagBetweenPathsEndsThePathPhase() {
        // Like --mdfind, the flags belong before the paths or after them; one in the
        // middle starts the expression, where a bare path is not a primary.
        #expect(throws: ParseError.self) { try parse(["/a", "--walk=only", "/b"]) }
    }

    @Test func flagIsNotAPathOperand() {
        #expect(throws: ParseError.self) { try parse(["--walk"]) }
        #expect(throws: ParseError.self) { try parse(["--walk=only", "--progress"]) }
    }

    @Test func walkModeProperties() {
        #expect(!WalkMode.off.walks)
        #expect(WalkMode.off.usesIndex)
        #expect(WalkMode.gaps.walks)
        #expect(WalkMode.gaps.usesIndex)
        #expect(WalkMode.only.walks)
        #expect(!WalkMode.only.usesIndex)
    }

    // MARK: - -content

    @Test func contentPrimary() throws {
        #expect(try parse([".", "-content", "zebra"]).expression == .primary(.content("zebra")))
        // The words are passed through as typed; the planner splits them.
        #expect(
            try parse([".", "-content", "zebra fish"]).expression
                == .primary(.content("zebra fish")))
        #expect(try parse([".", "-content", "zebra*"]).expression == .primary(.content("zebra*")))
        #expect(
            try parse([".", "-name", "*.md", "-content", "zebra"]).expression
                == .and([
                    .primary(.name("*.md", caseInsensitive: false)), .primary(.content("zebra")),
                ]))
        #expect(
            try parse([".", "!", "-content", "zebra"]).expression
                == .not(.primary(.content("zebra"))))
    }

    @Test func contentIsNotAnAction() throws {
        #expect(try parse([".", "-content", "zebra"]).implicitPrint)
    }

    @Test func contentRejectsEmptyText() {
        #expect(throws: ParseError.self) { try parse([".", "-content", ""]) }
        #expect(throws: ParseError.self) { try parse([".", "-content", "   "]) }
        #expect(throws: ParseError.self) { try parse([".", "-content", "\t\n"]) }
        #expect(throws: ParseError.self) { try parse([".", "-content"]) }
    }
}
