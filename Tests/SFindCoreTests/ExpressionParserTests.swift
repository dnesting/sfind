import SFindCore
import Testing

/// Operator grammar, precedence, implicit -print, and structural error cases.
@Suite struct ExpressionParserTests {
    func expr(_ tokens: String...) throws -> Expression? {
        try CommandParser().parse(["."] + tokens).expression
    }

    func command(_ tokens: String...) throws -> ParsedCommand {
        try CommandParser().parse(["."] + tokens)
    }

    let nameA = Expression.primary(.name("a", caseInsensitive: false))
    let nameB = Expression.primary(.name("b", caseInsensitive: false))
    let nameC = Expression.primary(.name("c", caseInsensitive: false))

    @Test func implicitAnd() throws {
        #expect(try expr("-name", "a", "-name", "b") == .and([nameA, nameB]))
    }

    @Test func explicitAndSpellings() throws {
        #expect(try expr("-name", "a", "-a", "-name", "b") == .and([nameA, nameB]))
        #expect(try expr("-name", "a", "-and", "-name", "b") == .and([nameA, nameB]))
    }

    @Test func orSpellings() throws {
        #expect(try expr("-name", "a", "-o", "-name", "b") == .or([nameA, nameB]))
        #expect(try expr("-name", "a", "-or", "-name", "b") == .or([nameA, nameB]))
    }

    @Test func andBindsTighterThanOr() throws {
        #expect(
            try expr("-name", "a", "-name", "b", "-o", "-name", "c")
                == .or([.and([nameA, nameB]), nameC]))
    }

    @Test func parensOverridePrecedence() throws {
        #expect(
            try expr("-name", "a", "(", "-name", "b", "-o", "-name", "c", ")")
                == .and([nameA, .or([nameB, nameC])]))
    }

    @Test func notSpellings() throws {
        #expect(try expr("!", "-name", "a") == .not(nameA))
        #expect(try expr("-not", "-name", "a") == .not(nameA))
        #expect(try expr("!", "!", "-name", "a") == .not(.not(nameA)))
    }

    @Test func notBindsTighterThanAnd() throws {
        #expect(try expr("!", "-name", "a", "-name", "b") == .and([.not(nameA), nameB]))
    }

    @Test func constants() throws {
        #expect(try expr("-true") == .primary(.alwaysTrue))
        #expect(try expr("-false") == .primary(.alwaysFalse))
    }

    @Test func unmatchedParens() {
        #expect(throws: ParseError.self) { try expr("(", "-name", "a") }
        #expect(throws: ParseError.self) { try expr(")") }
        #expect(throws: ParseError.self) { try expr("-name", "a", ")") }
    }

    @Test func unknownPrimary() {
        #expect(throws: ParseError("-frobnicate: unknown primary or operator")) {
            try expr("-frobnicate")
        }
    }

    // Implicit -print: suppressed by lexical presence of any action (including -delete,
    // undocumented), NOT by -quit. Verified find behavior.
    @Test func implicitPrintRules() throws {
        #expect(try command("-name", "a").implicitPrint)
        #expect(try command("-quit").implicitPrint)
        #expect(try command("-prune").implicitPrint)
        #expect(try command("-maxdepth", "1").implicitPrint)
        #expect(try command("-print").implicitPrint == false)
        #expect(try command("-print0").implicitPrint == false)
        #expect(try command("-ls").implicitPrint == false)
        #expect(try command("-delete").implicitPrint == false)
        #expect(try command("-exec", "true", ";").implicitPrint == false)
        #expect(try command("-execdir", "true", ";").implicitPrint == false)
        #expect(try command("-ok", "true", ";").implicitPrint == false)
        // Lexical presence suffices even in a never-evaluated branch.
        #expect(try command("-true", "-o", "-print").implicitPrint == false)
    }

    @Test func effectiveExpressionWrapsWithPrint() throws {
        let cmd = try command("-name", "a")
        #expect(cmd.effectiveExpression == .and([nameA, .primary(.print)]))
        let explicit = try command("-name", "a", "-print")
        #expect(explicit.effectiveExpression == .and([nameA, .primary(.print)]))
    }

    // Globals are recorded invocation-wide even from unevaluated branches, and the last
    // valued occurrence wins. Verified find behavior.
    @Test func globalsHoisted() throws {
        let cmd = try command("-true", "-o", "-maxdepth", "2")
        #expect(cmd.globals.maxDepth == 2)
        #expect(try command("-maxdepth", "1", "-maxdepth", "0").globals.maxDepth == 0)
        #expect(try command("-maxdepth", "0", "-maxdepth", "1").globals.maxDepth == 1)
        #expect(try command("-mindepth", "3").globals.minDepth == 3)
        #expect(try command("-xdev").globals.sameDevice)
        #expect(try command("-mount").globals.sameDevice)
        #expect(try command("-depth").globals.depthFirst)
        #expect(try command("-ignore_readdir_race").globals.ignoreReaddirRace)
        #expect(try command("-daystart").globals.daystart)
        #expect(try command("-regextype", "posix-extended").globals.regexDialect == .posixExtended)
    }

    @Test func depthDisambiguation() throws {
        // -depth followed by a number is the BSD depth-equals-n predicate.
        #expect(try expr("-depth", "2") == .primary(.depth(NumericArg(.exactly, 2))))
        #expect(try expr("-depth", "+0") == .primary(.depth(NumericArg(.moreThan, 0))))
        // Bare -depth (or followed by a non-number) is the global.
        let cmd = try command("-depth", "-name", "a")
        #expect(cmd.globals.depthFirst)
        #expect(cmd.expression == .and([.primary(.global(.depthFirst)), nameA]))
    }
}
