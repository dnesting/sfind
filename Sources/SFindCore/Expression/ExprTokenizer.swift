/// Splits a `--expr` string into expression tokens.
///
/// The motivating property is that expression metacharacters need no shell escaping inside
/// the (shell-quoted) string. Deliberately NOT full sh syntax — no operators, expansion,
/// globbing, or substitution:
/// - Whitespace separates tokens.
/// - Single quotes are literal spans; double quotes are spans where backslash escapes
///   `"` and `\`; outside quotes backslash escapes the next character.
/// - Unquoted `(` and `)` are self-delimiting tokens (no surrounding spaces required).
/// - Unquoted `!` is self-delimiting only where a new token would start, so negated
///   fnmatch classes like `[!a]*` survive intact even unquoted mid-token.
public enum ExprTokenizer {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unterminatedQuote(Character)
        case trailingBackslash

        public var description: String {
            switch self {
            case .unterminatedQuote(let q): return "unterminated \(q) quote in --expr string"
            case .trailingBackslash: return "trailing backslash in --expr string"
            }
        }
    }

    public static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        // Distinguishes an empty pending token ("" from adjacent quotes, e.g. '') from
        // no pending token at all.
        var hasCurrent = false

        func flush() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        var iterator = input.makeIterator()

        func next() -> Character? {
            iterator.next()
        }

        while let c = next() {
            switch c {
            case " ", "\t", "\n", "\r":
                flush()
            case "(", ")":
                flush()
                tokens.append(String(c))
            case "!" where !hasCurrent:
                tokens.append("!")
            case "'":
                hasCurrent = true
                var closed = false
                while let q = next() {
                    if q == "'" {
                        closed = true
                        break
                    }
                    current.append(q)
                }
                if !closed { throw Error.unterminatedQuote("'") }
            case "\"":
                hasCurrent = true
                var closed = false
                while let q = next() {
                    if q == "\"" {
                        closed = true
                        break
                    }
                    if q == "\\" {
                        guard let escaped = next() else { throw Error.trailingBackslash }
                        if escaped != "\"" && escaped != "\\" {
                            current.append("\\")
                        }
                        current.append(escaped)
                    } else {
                        current.append(q)
                    }
                }
                if !closed { throw Error.unterminatedQuote("\"") }
            case "\\":
                guard let escaped = next() else { throw Error.trailingBackslash }
                hasCurrent = true
                current.append(escaped)
            default:
                hasCurrent = true
                current.append(c)
            }
        }
        flush()
        return tokens
    }
}
