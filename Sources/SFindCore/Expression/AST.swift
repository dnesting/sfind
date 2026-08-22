import Foundation

/// A parsed find expression. Evaluation is strict left-to-right with short-circuiting
/// `and`/`or`, matching find(1).
public indirect enum Expression: Hashable, Sendable {
    case and([Expression])
    case or([Expression])
    case not(Expression)
    case primary(Primary)
}

/// Comparison relation for `[-+]n` numeric arguments: `+n` more than, `-n` less than,
/// `n` exactly.
public enum Relation: Hashable, Sendable {
    case exactly
    case lessThan
    case moreThan

    public func compare<T: Comparable>(_ value: T, to reference: T) -> Bool {
        switch self {
        case .exactly: return value == reference
        case .lessThan: return value < reference
        case .moreThan: return value > reference
        }
    }
}

/// A `[-+]n` argument.
public struct NumericArg: Hashable, Sendable {
    public var relation: Relation
    public var value: Int64

    public init(_ relation: Relation, _ value: Int64) {
        self.relation = relation
        self.value = value
    }
}

/// Which timestamp of a file a time predicate inspects.
public enum TimeField: Character, Equatable, Sendable {
    case access = "a"
    case birth = "B"
    case change = "c"
    case modify = "m"
}

/// The unit interpretation of a time argument. `days` compares `floor(age/86400)`,
/// `minutes` compares `ceil(age/60)` (both measured against /usr/bin/find at the
/// boundaries; the man page's "rounded up" wording is wrong for days). `seconds`
/// (from `smhdw` unit suffixes) compares raw seconds with no rounding.
public enum TimeAmount: Hashable, Sendable {
    case days(Int64)
    case minutes(Int64)
    case seconds(Int64)
}

/// Argument to -atime/-mtime/-ctime/-Btime and the -amin family.
public struct TimeArg: Hashable, Sendable {
    public var relation: Relation
    public var amount: TimeAmount

    public init(_ relation: Relation, _ amount: TimeAmount) {
        self.relation = relation
        self.amount = amount
    }
}

/// The reference operand of a -newerXY comparison: another file's timestamp, or
/// (for Y=t) a literal date string parsed lazily.
public enum NewerReference: Hashable, Sendable {
    case file(path: String, field: TimeField)
    case date(String)
}

/// Unit for -size arguments. `blocks` is the no-suffix form (st_size rounded UP to
/// 512-byte blocks, then compared); `bytes` compares exact bytes n × multiplier with
/// no rounding (verified macOS behavior; differs from GNU).
public enum SizeUnit: Hashable, Sendable {
    case blocks
    case bytes(multiplier: Int64)
}

public struct SizeArg: Hashable, Sendable {
    public var relation: Relation
    public var value: Int64
    public var unit: SizeUnit

    public init(_ relation: Relation, _ value: Int64, _ unit: SizeUnit) {
        self.relation = relation
        self.value = value
        self.unit = unit
    }
}

/// -perm matching mode: bare = exact 07777 match, `-mode` = all listed bits,
/// `+mode` (BSD) / `/mode` (GNU spelling) = any listed bit.
public enum PermMatch: Hashable, Sendable {
    case exact
    case allBits
    case anyBits
}

public struct PermArg: Hashable, Sendable {
    public var match: PermMatch
    /// Mode bits resolved at parse time (octal literal, or symbolic via setmode(3)
    /// applied to a zero base, matching find's umask-disregarding documentation).
    public var bits: UInt16
    /// The original mode string, for diagnostics.
    public var source: String

    public init(match: PermMatch, bits: UInt16, source: String) {
        self.match = match
        self.bits = bits
        self.source = source
    }
}

/// -flags argument: `chflags(1)` names resolved to bit masks via strtofflags(3).
public struct FlagsArg: Hashable, Sendable {
    public var match: PermMatch
    public var flags: UInt32
    public var notflags: UInt32
    public var source: String

    public init(match: PermMatch, flags: UInt32, notflags: UInt32, source: String) {
        self.match = match
        self.flags = flags
        self.notflags = notflags
        self.source = source
    }
}

/// -type letters accepted by macOS find (including the undocumented `w` whiteout).
public enum FileType: Character, Equatable, Sendable {
    case block = "b"
    case character = "c"
    case directory = "d"
    case regular = "f"
    case symlink = "l"
    case fifo = "p"
    case socket = "s"
    case whiteout = "w"
}

/// An -exec/-execdir/-ok/-okdir invocation.
public struct ExecSpec: Hashable, Sendable {
    /// Utility name and arguments; `{}` is substituted at run time (anywhere within a
    /// token, matching macOS find).
    public var argv: [String]
    /// `{} +` xargs-style batching form (always true; child failure poisons exit status).
    public var batch: Bool
    /// -execdir/-okdir: run from the file's directory with the unqualified name.
    public var fromFileDirectory: Bool
    /// -ok/-okdir: prompt on the terminal before running.
    public var prompted: Bool

    public init(argv: [String], batch: Bool, fromFileDirectory: Bool, prompted: Bool) {
        self.argv = argv
        self.batch = batch
        self.fromFileDirectory = fromFileDirectory
        self.prompted = prompted
    }
}

/// Regex dialect for -regex/-iregex (BSD BRE default; ERE via -E; GNU -regextype
/// selects explicitly).
public enum RegexDialect: String, Equatable, Sendable {
    case posixBasic = "posix-basic"
    case posixExtended = "posix-extended"
}

/// Global settings that find spells as always-true primaries. They are recorded in
/// `ParsedCommand.globals` at parse time and evaluate as `true` in expression position;
/// they apply to the whole invocation regardless of expression reachability, and the
/// last occurrence of a valued one wins (verified find behavior).
public enum GlobalPrimary: Hashable, Sendable {
    case maxDepth(Int)
    case minDepth(Int)
    case xdev
    case depthFirst
    case follow
    case ignoreReaddirRace
    case noIgnoreReaddirRace
    case noleaf
    case daystart
    case regextype(RegexDialect)
}

/// A find primary (predicate, action, or hoisted global).
public enum Primary: Hashable, Sendable {
    // Name and path.
    case name(String, caseInsensitive: Bool)
    case path(String, caseInsensitive: Bool)
    case lname(String, caseInsensitive: Bool)
    case regex(String, caseInsensitive: Bool)

    // Time.
    case time(TimeField, TimeArg)
    case newer(TimeField, NewerReference)

    // Ownership.
    case user(String)
    case group(String)
    case nouser
    case nogroup

    // Stat metadata.
    case type(FileType)
    case size(SizeArg)
    case perm(PermArg)
    case links(NumericArg)
    case inum(NumericArg)
    case samefile(String)
    case empty
    case sparse
    case flags(FlagsArg)
    case acl
    case xattr
    case xattrName(String)
    case fstype(String)

    // GNU access(2) extensions.
    case readable
    case writable
    case executable

    // Depth-as-a-number BSD primary (-depth n), distinct from the bare -depth global.
    case depth(NumericArg)

    // Constants.
    case alwaysTrue
    case alwaysFalse

    // Actions.
    case print
    case print0
    case ls
    case exec(ExecSpec)
    case delete
    case quit
    case printf(String)

    // Traversal.
    case prune

    // Hoisted globals (always true in expression position).
    case global(GlobalPrimary)
}

extension Primary {
    /// Whether this primary's lexical presence suppresses the implicit -print.
    /// Verified macOS behavior: the documented set plus -delete (undocumented);
    /// -quit does NOT suppress it.
    public var suppressesImplicitPrint: Bool {
        switch self {
        case .print, .print0, .ls, .exec, .delete, .printf:
            return true
        default:
            return false
        }
    }
}
