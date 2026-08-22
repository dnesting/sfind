import SFindCore
import Testing

@Suite struct ExprTokenizerTests {
    static let cases: [(input: String, expected: [String])] = [
        // Plain splitting.
        ("-name foo", ["-name", "foo"]),
        ("  -name   foo  ", ["-name", "foo"]),
        ("", []),
        ("   ", []),
        // Quotes preserve glob characters and spaces.
        ("-name \"*.md\"", ["-name", "*.md"]),
        ("-name '*.md'", ["-name", "*.md"]),
        ("-name 'two words'", ["-name", "two words"]),
        ("-name ''", ["-name", ""]),
        // The motivating case: parens without shell escaping.
        (
            "(-name \"*.md\" -o -name \"*.txt\") -mtime -7",
            ["(", "-name", "*.md", "-o", "-name", "*.txt", ")", "-mtime", "-7"]
        ),
        ("( -name a )", ["(", "-name", "a", ")"]),
        ("(-name a)", ["(", "-name", "a", ")"]),
        // ! self-delimits only at token start.
        ("! -name foo", ["!", "-name", "foo"]),
        ("!-name foo", ["!", "-name", "foo"]),
        ("-name [!a]*", ["-name", "[!a]*"]),
        ("!!", ["!", "!"]),
        // Quoted metacharacters are literal.
        ("-name '(odd) file*'", ["-name", "(odd) file*"]),
        ("-name '!bang'", ["-name", "!bang"]),
        // Backslash escapes outside quotes.
        ("-name \\(paren\\)", ["-name", "(paren)"]),
        ("-name a\\ b", ["-name", "a b"]),
        // Inside double quotes, backslash escapes only \" and \\.
        ("-name \"a\\\"b\"", ["-name", "a\"b"]),
        ("-name \"a\\\\b\"", ["-name", "a\\b"]),
        ("-name \"a\\nb\"", ["-name", "a\\nb"]),
        // Adjacent quoted/unquoted segments concatenate.
        ("-name 'a'b\"c\"", ["-name", "abc"]),
    ]

    @Test(arguments: cases.indices)
    func tokenizes(_ index: Int) throws {
        let (input, expected) = Self.cases[index]
        #expect(try ExprTokenizer.tokenize(input) == expected, "input: \(input)")
    }

    @Test func unterminatedSingleQuote() {
        #expect(throws: ExprTokenizer.Error.unterminatedQuote("'")) {
            try ExprTokenizer.tokenize("-name 'oops")
        }
    }

    @Test func unterminatedDoubleQuote() {
        #expect(throws: ExprTokenizer.Error.unterminatedQuote("\"")) {
            try ExprTokenizer.tokenize("-name \"oops")
        }
    }

    @Test func trailingBackslash() {
        #expect(throws: ExprTokenizer.Error.trailingBackslash) {
            try ExprTokenizer.tokenize("-name foo\\")
        }
    }
}
