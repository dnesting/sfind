import Darwin
import Foundation

/// A parse-time failure, with a find-style message (sfind's stderr prefix is added at
/// output time).
public struct ParseError: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

enum ArgParsing {
    /// Splits a leading `+`/`-` relation off a numeric-ish argument.
    static func relation(_ s: Substring) -> (Relation, Substring) {
        switch s.first {
        case "+": return (.moreThan, s.dropFirst())
        case "-": return (.lessThan, s.dropFirst())
        default: return (.exactly, s)
        }
    }

    /// `[-+]n` plain decimal argument.
    static func numeric(_ arg: String, primary: String) throws -> NumericArg {
        let (rel, rest) = relation(arg[...])
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber), let value = Int64(rest) else {
            throw ParseError("\(primary): \(arg): illegal numeric value")
        }
        return NumericArg(rel, value)
    }

    /// A bare non-negative integer (for -maxdepth/-mindepth).
    static func plainInt(_ arg: String, primary: String) throws -> Int {
        guard !arg.isEmpty, arg.allSatisfy(\.isNumber), let value = Int(arg) else {
            throw ParseError("\(primary): \(arg): illegal numeric value")
        }
        return value
    }

    /// True if the token looks like a `-depth n` numeric argument (used to disambiguate
    /// the -depth global from the BSD -depth-equals-n primary).
    static func looksNumeric(_ arg: String) -> Bool {
        let (_, rest) = relation(arg[...])
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// `[-+]n[smhdw]` time argument. No suffix: days (or minutes for the *min forms).
    /// With suffixes: raw seconds, terms combinable (`-1h30m`).
    static func time(_ arg: String, primary: String, defaultUnit: TimeAmount) throws -> TimeArg {
        let (rel, rest) = relation(arg[...])
        guard !rest.isEmpty else {
            throw ParseError("\(primary): \(arg): illegal time value")
        }
        if rest.allSatisfy(\.isNumber) {
            guard let value = Int64(rest) else {
                throw ParseError("\(primary): \(arg): illegal time value")
            }
            switch defaultUnit {
            case .days: return TimeArg(rel, .days(value))
            case .minutes: return TimeArg(rel, .minutes(value))
            case .seconds: return TimeArg(rel, .seconds(value))
            }
        }
        // Unit-suffixed form: one or more "<digits><unit>" terms.
        var seconds: Int64 = 0
        var digits = ""
        for c in rest {
            if c.isNumber {
                digits.append(c)
                continue
            }
            guard !digits.isEmpty, let value = Int64(digits) else {
                throw ParseError("\(primary): \(arg): illegal time value")
            }
            let multiplier: Int64
            switch c {
            case "s": multiplier = 1
            case "m": multiplier = 60
            case "h": multiplier = 3600
            case "d": multiplier = 86400
            case "w": multiplier = 604_800
            default: throw ParseError("\(primary): \(arg): illegal time value")
            }
            seconds += value * multiplier
            digits = ""
        }
        guard digits.isEmpty else {
            // Trailing digits without a unit (e.g. "1h30") are invalid.
            throw ParseError("\(primary): \(arg): illegal time value")
        }
        return TimeArg(rel, .seconds(seconds))
    }

    /// `[-+]n[ckMGTP]` size argument.
    static func size(_ arg: String, primary: String) throws -> SizeArg {
        let (rel, rest) = relation(arg[...])
        var digitsPart = rest
        var unit = SizeUnit.blocks
        if let last = rest.last, !last.isNumber {
            digitsPart = rest.dropLast()
            switch last {
            case "c": unit = .bytes(multiplier: 1)
            case "k": unit = .bytes(multiplier: 1 << 10)
            case "M": unit = .bytes(multiplier: 1 << 20)
            case "G": unit = .bytes(multiplier: 1 << 30)
            case "T": unit = .bytes(multiplier: 1 << 40)
            case "P": unit = .bytes(multiplier: 1 << 50)
            default: throw ParseError("\(primary): \(arg): illegal trailing character")
            }
        }
        guard !digitsPart.isEmpty, digitsPart.allSatisfy(\.isNumber),
            let value = Int64(digitsPart)
        else {
            throw ParseError("\(primary): \(arg): illegal size value")
        }
        return SizeArg(rel, value, unit)
    }

    /// `-perm [-+/]mode` argument, octal or symbolic. Symbolic modes are resolved via
    /// setmode(3)/getmode(3) against a zero base, matching find's implementation.
    static func perm(_ arg: String, primary: String) throws -> PermArg {
        var match = PermMatch.exact
        var modeString = arg[...]
        switch modeString.first {
        case "-":
            match = .allBits
            modeString = modeString.dropFirst()
        case "+", "/":
            // BSD spells any-bit as +mode; GNU as /mode. sfind accepts both.
            match = .anyBits
            modeString = modeString.dropFirst()
        default:
            break
        }
        let text = String(modeString)
        guard !text.isEmpty, let set = setmode(text) else {
            throw ParseError("\(primary): \(arg): illegal mode string")
        }
        defer { free(set) }
        let bits = UInt16(getmode(set, 0) & 0o7777)
        return PermArg(match: match, bits: bits, source: arg)
    }

    /// `-flags [-+]flags,notflags` argument, resolved via strtofflags(3). Names prefixed
    /// `no` (except `nodump`) are notflags.
    static func flags(_ arg: String, primary: String) throws -> FlagsArg {
        var match = PermMatch.exact
        var text = arg[...]
        switch text.first {
        case "-":
            match = .allBits
            text = text.dropFirst()
        case "+":
            match = .anyBits
            text = text.dropFirst()
        default:
            break
        }
        var setFlags: UInt = 0
        var clearFlags: UInt = 0
        var result: Int32 = -1
        String(text).withCString { cstr in
            let mutable = strdup(cstr)
            defer { free(mutable) }
            var cursor: UnsafeMutablePointer<CChar>? = mutable
            result = strtofflags(&cursor, &setFlags, &clearFlags)
        }
        guard result == 0 else {
            throw ParseError("\(primary): \(arg): illegal flags string")
        }
        return FlagsArg(
            match: match, flags: UInt32(truncatingIfNeeded: setFlags),
            notflags: UInt32(truncatingIfNeeded: clearFlags), source: arg)
    }
}
