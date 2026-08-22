import Foundation

/// Parses a full sfind command line: getopt-style options, then paths, then the
/// expression. `--expr STRING` arguments are tokenized (see ExprTokenizer) and spliced
/// into the expression token stream where they appear.
public struct CommandParser {
    public init() {}

    public func parse(_ arguments: [String]) throws -> ParsedCommand {
        var options = FindOptions()
        var globals = Globals()
        var paths: [String] = []
        var index = 0

        // Option phase: getopt-style. Bundling works (-EXdsx); parsing stops at the
        // first non-option argument or at "--". sfind's own long flags are accepted
        // here too.
        optionLoop: while index < arguments.count {
            let arg = arguments[index]
            if arg == "--mdfind" {
                options.translateOnly = true
                index += 1
                continue
            }
            guard arg.count >= 2, arg.hasPrefix("-"), !arg.hasPrefix("--") else { break }
            var chars = arg.dropFirst()
            // A bundle is valid when every char is an option letter, except that an "f"
            // swallows the rest of the token as its path argument (-fPATH). A token
            // like "-name" is not a valid bundle; stop the option phase and let the
            // path/expression phases handle it (find's getopt errors here, but the
            // missing-path check below reports the same failure mode).
            var isValidBundle = true
            var scan = chars
            while let c = scan.first {
                scan = scan.dropFirst()
                if c == "f" { break }
                if !"HLPEXdsx".contains(c) {
                    isValidBundle = false
                    break
                }
            }
            guard isValidBundle else { break }
            index += 1
            while let c = chars.first {
                chars = chars.dropFirst()
                switch c {
                case "H": options.symlinks = .commandLine
                case "L": options.symlinks = .always
                case "P": options.symlinks = .never
                case "E": options.extendedRegex = true
                case "X": options.safeOutput = true
                case "d": globals.depthFirst = true
                case "s": options.sorted = true
                case "x": globals.sameDevice = true
                case "f":
                    // -fPATH or -f PATH.
                    if !chars.isEmpty {
                        paths.append(String(chars))
                        chars = ""
                    } else {
                        guard index < arguments.count else {
                            throw ParseError("option requires an argument -- f")
                        }
                        paths.append(arguments[index])
                        index += 1
                    }
                default:
                    break
                }
            }
        }
        if index < arguments.count, arguments[index] == "--" {
            index += 1
        }

        // Path phase: operands until a token that begins the expression.
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "(" || arg == ")" || arg == "!" { break }
            if arg.count > 1 && arg.hasPrefix("-") { break }
            paths.append(arg)
            index += 1
        }

        guard !paths.isEmpty else {
            throw ParseError("no path operands (sfind, like find, requires at least one path)")
        }

        // Expression phase: splice --expr strings, then recursive descent.
        var tokens: [String] = []
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--mdfind" {
                options.translateOnly = true
            } else if arg == "--expr" {
                index += 1
                guard index < arguments.count else {
                    throw ParseError("--expr: requires additional arguments")
                }
                tokens.append(contentsOf: try ExprTokenizer.tokenize(arguments[index]))
            } else if arg.hasPrefix("--expr=") {
                tokens.append(
                    contentsOf: try ExprTokenizer.tokenize(String(arg.dropFirst("--expr=".count))))
            } else {
                tokens.append(arg)
            }
            index += 1
        }

        var parser = ExpressionParser(tokens: tokens, globals: globals)
        let expression = try parser.parseAll()
        globals = parser.globals
        if globals.follow {
            // -follow is the deprecated global-primary form of -L.
            options.symlinks = .always
        }

        return ParsedCommand(
            options: options,
            globals: globals,
            paths: paths,
            expression: expression,
            implicitPrint: !parser.sawActionPrimary)
    }
}

/// Recursive-descent parser for the expression grammar:
///
///     or   := and (("-o" | "-or") and)*
///     and  := unary (("-a" | "-and")? unary)*
///     unary := ("!" | "-not") unary | "(" or ")" | primary
struct ExpressionParser {
    var tokens: [String]
    var position = 0
    var globals: Globals
    var sawActionPrimary = false

    init(tokens: [String], globals: Globals) {
        self.tokens = tokens
        self.globals = globals
    }

    var atEnd: Bool { position >= tokens.count }

    func peek() -> String? { atEnd ? nil : tokens[position] }

    mutating func advance() -> String {
        defer { position += 1 }
        return tokens[position]
    }

    /// Consumes the required argument of a primary.
    mutating func argument(for primary: String) throws -> String {
        guard !atEnd else {
            throw ParseError("\(primary): requires additional arguments")
        }
        return advance()
    }

    mutating func parseAll() throws -> Expression? {
        if atEnd { return nil }
        let expr = try parseOr()
        if let extra = peek() {
            if extra == ")" { throw ParseError("): no beginning '('") }
            throw ParseError("\(extra): unexpected operand")
        }
        return expr
    }

    mutating func parseOr() throws -> Expression {
        var terms = [try parseAnd()]
        while let token = peek(), token == "-o" || token == "-or" {
            _ = advance()
            terms.append(try parseAnd())
        }
        return terms.count == 1 ? terms[0] : .or(terms)
    }

    mutating func parseAnd() throws -> Expression {
        var terms = [try parseUnary()]
        while let token = peek() {
            if token == "-a" || token == "-and" {
                _ = advance()
                terms.append(try parseUnary())
            } else if token == "-o" || token == "-or" || token == ")" {
                break
            } else {
                terms.append(try parseUnary())
            }
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    mutating func parseUnary() throws -> Expression {
        guard let token = peek() else {
            throw ParseError("expression expected")
        }
        if token == "!" || token == "-not" {
            _ = advance()
            return .not(try parseUnary())
        }
        if token == "(" {
            _ = advance()
            let inner = try parseOr()
            guard !atEnd, advance() == ")" else {
                throw ParseError("(: missing closing ')'")
            }
            return inner
        }
        if token == ")" {
            throw ParseError("): no beginning '('")
        }
        return .primary(try parsePrimary())
    }

    mutating func parsePrimary() throws -> Primary {
        let token = advance()
        let primary = try parsePrimaryNamed(token)
        if primary.suppressesImplicitPrint {
            sawActionPrimary = true
        }
        return primary
    }

    private mutating func parsePrimaryNamed(_ token: String) throws -> Primary {
        switch token {
        // Name and path.
        case "-name":
            return .name(try argument(for: token), caseInsensitive: false)
        case "-iname":
            return .name(try argument(for: token), caseInsensitive: true)
        case "-path", "-wholename":
            return .path(try argument(for: token), caseInsensitive: false)
        case "-ipath", "-iwholename":
            return .path(try argument(for: token), caseInsensitive: true)
        case "-lname":
            return .lname(try argument(for: token), caseInsensitive: false)
        case "-ilname":
            return .lname(try argument(for: token), caseInsensitive: true)
        case "-regex":
            return .regex(try argument(for: token), caseInsensitive: false)
        case "-iregex":
            return .regex(try argument(for: token), caseInsensitive: true)

        // Time.
        case "-atime", "-ctime", "-mtime", "-Btime":
            let field = TimeField(rawValue: token[token.index(token.startIndex, offsetBy: 1)])!
            return .time(
                field,
                try ArgParsing.time(argument(for: token), primary: token, defaultUnit: .days(0)))
        case "-amin", "-cmin", "-mmin", "-Bmin":
            let field = TimeField(rawValue: token[token.index(token.startIndex, offsetBy: 1)])!
            return .time(
                field,
                try ArgParsing.time(argument(for: token), primary: token, defaultUnit: .minutes(0)))
        case "-newer", "-mnewer":
            return .newer(.modify, .file(path: try argument(for: token), field: .modify))
        case "-anewer":
            return .newer(.access, .file(path: try argument(for: token), field: .modify))
        case "-cnewer":
            return .newer(.change, .file(path: try argument(for: token), field: .modify))
        case "-Bnewer":
            return .newer(.birth, .file(path: try argument(for: token), field: .modify))

        // Ownership.
        case "-user", "-uid":
            return .user(try argument(for: token))
        case "-group", "-gid":
            return .group(try argument(for: token))
        case "-nouser":
            return .nouser
        case "-nogroup":
            return .nogroup

        // Stat metadata.
        case "-type":
            let arg = try argument(for: token)
            guard arg.count == 1, let type = FileType(rawValue: arg.first!) else {
                throw ParseError("-type: \(arg): unknown type")
            }
            return .type(type)
        case "-size":
            return .size(try ArgParsing.size(argument(for: token), primary: token))
        case "-perm":
            return .perm(try ArgParsing.perm(argument(for: token), primary: token))
        case "-links":
            return .links(try ArgParsing.numeric(argument(for: token), primary: token))
        case "-inum":
            return .inum(try ArgParsing.numeric(argument(for: token), primary: token))
        case "-samefile":
            return .samefile(try argument(for: token))
        case "-empty":
            return .empty
        case "-sparse":
            return .sparse
        case "-flags":
            return .flags(try ArgParsing.flags(argument(for: token), primary: token))
        case "-acl":
            return .acl
        case "-xattr":
            return .xattr
        case "-xattrname":
            return .xattrName(try argument(for: token))
        case "-fstype":
            return .fstype(try argument(for: token))

        // GNU access(2) extensions.
        case "-readable":
            return .readable
        case "-writable":
            return .writable
        case "-executable":
            return .executable

        // Constants.
        case "-true":
            return .alwaysTrue
        case "-false":
            return .alwaysFalse

        // Actions.
        case "-print":
            return .print
        case "-print0":
            return .print0
        case "-ls":
            return .ls
        case "-exec":
            return .exec(try parseExec(token, fromFileDirectory: false, prompted: false))
        case "-execdir":
            return .exec(try parseExec(token, fromFileDirectory: true, prompted: false))
        case "-ok":
            return .exec(try parseExec(token, fromFileDirectory: false, prompted: true))
        case "-okdir":
            return .exec(try parseExec(token, fromFileDirectory: true, prompted: true))
        case "-delete":
            return .delete
        case "-quit":
            return .quit
        case "-printf":
            return .printf(try argument(for: token))

        // Traversal.
        case "-prune":
            return .prune

        // Globals (always true in expression position; recorded for the whole run).
        case "-maxdepth":
            globals.maxDepth = try ArgParsing.plainInt(argument(for: token), primary: token)
            return .global(.maxDepth(globals.maxDepth!))
        case "-mindepth":
            globals.minDepth = try ArgParsing.plainInt(argument(for: token), primary: token)
            return .global(.minDepth(globals.minDepth!))
        case "-xdev", "-mount":
            globals.sameDevice = true
            return .global(.xdev)
        case "-depth":
            // BSD: `-depth n` (a real predicate) vs bare `-depth` (global), decided by
            // whether the next token is numeric.
            if let next = peek(), ArgParsing.looksNumeric(next) {
                return .depth(try ArgParsing.numeric(advance(), primary: token))
            }
            globals.depthFirst = true
            return .global(.depthFirst)
        case "-follow":
            globals.follow = true
            return .global(.follow)
        case "-ignore_readdir_race":
            globals.ignoreReaddirRace = true
            return .global(.ignoreReaddirRace)
        case "-noignore_readdir_race":
            globals.ignoreReaddirRace = false
            return .global(.noIgnoreReaddirRace)
        case "-noleaf":
            return .global(.noleaf)
        case "-daystart":
            globals.daystart = true
            return .global(.daystart)
        case "-regextype":
            let arg = try argument(for: token)
            guard let dialect = RegexDialect(rawValue: arg) else {
                throw ParseError("-regextype: \(arg): unknown regular expression type")
            }
            globals.regexDialect = dialect
            return .global(.regextype(dialect))

        default:
            if let newer = try parseNewerXY(token) {
                return newer
            }
            throw ParseError("\(token): unknown primary or operator")
        }
    }

    /// The -newerXY matrix: X ∈ {a,B,c,m}, Y ∈ {a,B,c,m,t}.
    private mutating func parseNewerXY(_ token: String) throws -> Primary? {
        guard token.hasPrefix("-newer"), token.count == 8 else { return nil }
        let suffix = Array(token.dropFirst("-newer".count))
        guard let x = TimeField(rawValue: suffix[0]) else { return nil }
        let arg = try argument(for: token)
        if suffix[1] == "t" {
            return .newer(x, .date(arg))
        }
        guard let y = TimeField(rawValue: suffix[1]) else { return nil }
        return .newer(x, .file(path: arg, field: y))
    }

    /// Parses -exec/-execdir/-ok/-okdir argument lists. The `;` form ends at a literal
    /// `;` token; the `{} +` form requires the literal `{}` immediately before `+`
    /// (verified find behavior — anything else is "no terminating \";\" or \"+\"").
    /// -ok/-okdir accept only the `;` form.
    private mutating func parseExec(
        _ primary: String, fromFileDirectory: Bool, prompted: Bool
    ) throws -> ExecSpec {
        var argv: [String] = []
        while !atEnd {
            let token = advance()
            if token == ";" {
                guard !argv.isEmpty else {
                    throw ParseError("\(primary): no utility name")
                }
                return ExecSpec(
                    argv: argv, batch: false, fromFileDirectory: fromFileDirectory,
                    prompted: prompted)
            }
            if token == "+" && argv.last == "{}" && !prompted {
                return ExecSpec(
                    argv: argv, batch: true, fromFileDirectory: fromFileDirectory,
                    prompted: prompted)
            }
            argv.append(token)
        }
        throw ParseError("\(primary): no terminating \";\" or \"+\"")
    }
}
