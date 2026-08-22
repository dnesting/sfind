/// Symlink-following mode selected by -H/-L/-P (last one wins; -P is the default).
public enum SymlinkMode: Equatable, Sendable {
    /// -P: lstat everywhere.
    case never
    /// -H: stat for command-line path operands only (lstat fallback on dangling).
    case commandLine
    /// -L: stat everywhere (lstat fallback on broken links).
    case always
}

/// Pre-path command-line options.
public struct FindOptions: Equatable, Sendable {
    public var symlinks: SymlinkMode = .never
    /// -E: -regex/-iregex use extended REs.
    public var extendedRegex = false
    /// -X: skip files whose names contain characters unsafe for xargs, with a diagnostic.
    public var safeOutput = false
    /// -s: lexicographic result order.
    public var sorted = false
    /// --mdfind: print the equivalent mdfind invocation instead of running the query.
    public var translateOnly = false

    public init() {}
}

/// Invocation-wide settings, merged from options and from always-true global primaries
/// hoisted out of the expression (-maxdepth, -xdev, …). For repeated valued globals the
/// last occurrence wins (verified find behavior).
public struct Globals: Equatable, Sendable {
    public var maxDepth: Int? = nil
    public var minDepth: Int? = nil
    /// -x / -xdev / -mount: do not cross device boundaries.
    public var sameDevice = false
    /// -d / -depth: depth-first (post-order); also makes -prune inert.
    public var depthFirst = false
    /// -ignore_readdir_race: silently drop candidates that vanish before stat.
    public var ignoreReaddirRace = false
    /// -follow: deprecated primary form of -L (merged into options.symlinks after parse).
    public var follow = false
    /// -daystart (GNU extension): day boundaries measured from the start of today.
    public var daystart = false
    /// -regextype (GNU extension): overrides the -E/BRE default for -regex/-iregex.
    public var regexDialect: RegexDialect? = nil

    public init() {}
}

/// The fully parsed command line.
public struct ParsedCommand: Equatable, Sendable {
    public var options: FindOptions
    public var globals: Globals
    public var paths: [String]
    /// The expression as written; nil when absent (equivalent to -print).
    public var expression: Expression?
    /// Whether the implicit -print applies (no action primary present lexically;
    /// -delete counts as an action, -quit does not — verified find behavior).
    public var implicitPrint: Bool

    public init(
        options: FindOptions, globals: Globals, paths: [String], expression: Expression?,
        implicitPrint: Bool
    ) {
        self.options = options
        self.globals = globals
        self.paths = paths
        self.expression = expression
        self.implicitPrint = implicitPrint
    }

    /// The expression actually evaluated: `( written ) -print` when the implicit
    /// -print applies.
    public var effectiveExpression: Expression {
        let base = expression ?? .primary(.alwaysTrue)
        return implicitPrint ? .and([base, .primary(.print)]) : base
    }
}
