import Darwin

/// A compiled POSIX regular expression (regcomp/regexec) — the engine find uses.
/// NSRegularExpression is ICU and deliberately not used.
public final class PosixRegex {
    private var preg = regex_t()

    public init(pattern: String, extended: Bool, caseInsensitive: Bool) throws {
        var flags: Int32 = extended ? REG_EXTENDED : 0
        if caseInsensitive { flags |= REG_ICASE }
        let rc = regcomp(&preg, pattern, flags)
        guard rc == 0 else {
            var buffer = [UInt8](repeating: 0, count: 256)
            buffer.withUnsafeMutableBytes { raw in
                let cbuf = raw.bindMemory(to: CChar.self)
                _ = regerror(rc, &preg, cbuf.baseAddress!, cbuf.count)
            }
            let message = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            throw ParseError("\(pattern): \(message)")
        }
    }

    deinit {
        regfree(&preg)
    }

    /// True when the pattern matches the ENTIRE string (find's -regex is implicitly
    /// anchored at both ends).
    public func matchesWholeString(_ string: String) -> Bool {
        var match = regmatch_t()
        let utf8Length = string.utf8.count
        let rc = regexec(&preg, string, 1, &match, 0)
        guard rc == 0 else { return false }
        return match.rm_so == 0 && match.rm_eo == regoff_t(utf8Length)
    }
}
