import SFindCore
import Testing

@Suite struct OptionParserTests {
    func parse(_ args: [String]) throws -> ParsedCommand {
        try CommandParser().parse(args)
    }

    @Test func defaults() throws {
        let cmd = try parse(["."])
        #expect(cmd.options == FindOptions())
        #expect(cmd.paths == ["."])
        #expect(cmd.expression == nil)
        #expect(cmd.implicitPrint)
        #expect(cmd.effectiveExpression == .and([.primary(.alwaysTrue), .primary(.print)]))
    }

    @Test func symlinkModesLastWins() throws {
        #expect(try parse(["-H", "."]).options.symlinks == .commandLine)
        #expect(try parse(["-L", "."]).options.symlinks == .always)
        #expect(try parse(["-P", "."]).options.symlinks == .never)
        #expect(try parse(["-H", "-L", "."]).options.symlinks == .always)
        #expect(try parse(["-L", "-P", "."]).options.symlinks == .never)
    }

    @Test func bundledOptions() throws {
        let cmd = try parse(["-EXdsx", "."])
        #expect(cmd.options.extendedRegex)
        #expect(cmd.options.safeOutput)
        #expect(cmd.options.sorted)
        #expect(cmd.globals.depthFirst)
        #expect(cmd.globals.sameDevice)
    }

    @Test func fOptionSeparateAndAttached() throws {
        #expect(try parse(["-f", "/a", "/b"]).paths == ["/a", "/b"])
        #expect(try parse(["-f/a", "."]).paths == ["/a", "."])
        // -f allows paths that look like expression starters.
        #expect(try parse(["-f", "-weird", "."]).paths == ["-weird", "."])
    }

    @Test func multiplePaths() throws {
        let cmd = try parse(["/a", "/b", "/c", "-name", "x"])
        #expect(cmd.paths == ["/a", "/b", "/c"])
        #expect(cmd.expression == .primary(.name("x", caseInsensitive: false)))
    }

    @Test func doubleDashEndsOptions() throws {
        let cmd = try parse(["--", ".", "-name", "x"])
        #expect(cmd.paths == ["."])
        #expect(cmd.expression == .primary(.name("x", caseInsensitive: false)))
    }

    @Test func noPathIsUsageError() {
        // Verified: /usr/bin/find with no path operand is a usage error (it does not
        // default to "." the way GNU find does).
        #expect(throws: ParseError.self) { try parse([]) }
        #expect(throws: ParseError.self) { try parse(["-name", "foo"]) }
    }

    @Test func expressionStartsAtBangOrParen() throws {
        #expect(
            try parse([".", "!", "-name", "x"]).expression
                == .not(.primary(.name("x", caseInsensitive: false))))
        #expect(
            try parse([".", "(", "-name", "x", ")"]).expression
                == .primary(.name("x", caseInsensitive: false)))
    }

    @Test func exprFlagSplices() throws {
        let discrete = try parse(
            [".", "(", "-name", "*.md", "-o", "-name", "*.txt", ")", "-mtime", "-7"])
        let viaString = try parse(
            [".", "--expr", "(-name \"*.md\" -o -name \"*.txt\") -mtime -7"])
        let viaEquals = try parse(
            [".", "--expr=(-name \"*.md\" -o -name \"*.txt\") -mtime -7"])
        #expect(viaString.expression == discrete.expression)
        #expect(viaEquals.expression == discrete.expression)
    }

    @Test func exprMixesWithDiscreteTokens() throws {
        let mixed = try parse([".", "--expr", "-name \"*.md\"", "-mtime", "-7"])
        let discrete = try parse([".", "-name", "*.md", "-mtime", "-7"])
        #expect(mixed.expression == discrete.expression)
    }

    @Test func exprRequiresArgument() {
        #expect(throws: ParseError.self) { try parse([".", "--expr"]) }
    }
}
