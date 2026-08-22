import Darwin
import Foundation

/// Inputs the planner needs from the outside world, injectable for deterministic tests.
public struct PlannerEnvironment: Sendable {
    /// The invocation's fixed "now" (find captures it once at startup).
    public var now: Date
    public var resolveUser: @Sendable (String) throws -> UInt32
    public var resolveGroup: @Sendable (String) throws -> UInt32
    public var resolveNewerDate: @Sendable (NewerReference) throws -> Date

    public init(
        now: Date,
        resolveUser: @escaping @Sendable (String) throws -> UInt32,
        resolveGroup: @escaping @Sendable (String) throws -> UInt32,
        resolveNewerDate: @escaping @Sendable (NewerReference) throws -> Date
    ) {
        self.now = now
        self.resolveUser = resolveUser
        self.resolveGroup = resolveGroup
        self.resolveNewerDate = resolveNewerDate
    }

    public static func live(now: Date = Date()) -> PlannerEnvironment {
        PlannerEnvironment(
            now: now,
            resolveUser: { name in
                if let pw = getpwnam(name) { return pw.pointee.pw_uid }
                if let uid = UInt32(name) { return uid }
                throw ParseError("-user: \(name): no such user")
            },
            resolveGroup: { name in
                if let gr = getgrnam(name) { return gr.pointee.gr_gid }
                if let gid = UInt32(name) { return gid }
                throw ParseError("-group: \(name): no such group")
            },
            resolveNewerDate: { reference in
                switch reference {
                case .file(let path, let field):
                    guard let info = FileInfo.statFollowing(path) else {
                        throw ParseError("\(path): No such file or directory")
                    }
                    return info.date(field)
                case .date(let text):
                    guard let date = DateParser.parse(text, now: now) else {
                        throw ParseError("Can't parse date/time: \(text)")
                    }
                    return date
                }
            })
    }
}

/// The MDQuery side of an execution plan: the query string (a recall-oriented
/// over-approximation of the expression) and the completeness warnings.
public struct QueryPlan: Equatable, Sendable {
    /// The MDQuery to run, or nil when the expression provably matches nothing the
    /// index can return (e.g. `-type l`) — skip the query entirely.
    public var queryString: String?
    public var warnings: [PlanWarning]
    /// Predicates the query cannot express (their filtering happens post-query), in
    /// expression order. Used by --mdfind to note that its results are a superset.
    public var postFilterOnly: [String] = []

    /// The tier-safe match-all: `kMDItemFSName == "*"` alone returns nothing in
    /// fully-indexed trees, and `public.item` alone returns nothing in the reduced
    /// hidden-directory tier (both verified), so the base ORs them.
    public static let matchAll =
        "(kMDItemContentTypeTree == \"public.item\" || kMDItemFSName == \"*\")"
}

/// Translates an expression into its MDQuery narrowing. The post-filter re-verifies
/// every predicate, so narrowing only needs to be a superset of the true matches among
/// indexed files — never claim exactness (which is also why negations contribute no
/// narrowing: ¬superset is not a superset of ¬exact).
public struct Planner {
    public var environment: PlannerEnvironment
    /// True when a search root is itself a hidden directory: such scopes serve only
    /// {FSName, owner uid/gid, creation/modification dates} (verified), so narrowing
    /// on content type or size would silently drop results.
    public var reducedTier: Bool

    public init(environment: PlannerEnvironment, reducedTier: Bool = false) {
        self.environment = environment
        self.reducedTier = reducedTier
    }

    public func plan(_ command: ParsedCommand) throws -> QueryPlan {
        let expression = command.expression ?? .primary(.alwaysTrue)
        var warnings: [PlanWarning] = []
        collectWarnings(expression, into: &warnings)
        let narrowing = try narrow(
            expression, daystart: command.globals.daystart)
        var postOnly: [String] = []
        collectPostFilterOnly(expression, underNegation: false, into: &postOnly)
        switch narrowing {
        case .impossible:
            return QueryPlan(queryString: nil, warnings: warnings, postFilterOnly: postOnly)
        case .unconstrained:
            return QueryPlan(
                queryString: QueryPlan.matchAll, warnings: warnings, postFilterOnly: postOnly)
        case .query(let q):
            return QueryPlan(queryString: q, warnings: warnings, postFilterOnly: postOnly)
        }
    }

    /// Names the predicates whose truth the query cannot express: those with no index
    /// narrowing, plus anything under a negation (whose narrowing must be discarded).
    private func collectPostFilterOnly(
        _ expression: Expression, underNegation: Bool, into result: inout [String]
    ) {
        func add(_ name: String) {
            if !result.contains(name) { result.append(name) }
        }
        switch expression {
        case .and(let children), .or(let children):
            for child in children {
                collectPostFilterOnly(child, underNegation: underNegation, into: &result)
            }
        case .not(let child):
            collectPostFilterOnly(child, underNegation: true, into: &result)
        case .primary(let primary):
            guard let name = primary.predicateDisplayName else { return }
            if underNegation {
                add("! " + name)
                return
            }
            if case .unconstrained? = try? narrowPrimary(primary, daystart: false) {
                add(name)
            }
        }
    }

    // MARK: - Warnings

    private func collectWarnings(_ expression: Expression, into warnings: inout [PlanWarning]) {
        func add(_ w: PlanWarning) {
            if !warnings.contains(w) { warnings.append(w) }
        }
        switch expression {
        case .and(let children), .or(let children):
            for child in children { collectWarnings(child, into: &warnings) }
        case .not(let child):
            collectWarnings(child, into: &warnings)
        case .primary(let primary):
            switch primary {
            case .type(let t) where t != .directory && t != .regular:
                add(.invisibleType(t))
            case .lname:
                add(.symlinkContents)
            case .name(let pattern, let ci) where pattern.hasPrefix("."):
                add(.dotPattern(ci ? "-iname" : "-name", pattern))
            default:
                break
            }
        }
    }

    // MARK: - Narrowing

    private enum Narrowing {
        case unconstrained
        case impossible
        case query(String)
    }

    private func narrow(_ expression: Expression, daystart: Bool) throws -> Narrowing {
        switch expression {
        case .and(let children):
            var parts: [String] = []
            for child in children {
                switch try narrow(child, daystart: daystart) {
                case .impossible: return .impossible
                case .unconstrained: continue
                case .query(let q): parts.append(q)
                }
            }
            if parts.isEmpty { return .unconstrained }
            if parts.count == 1 { return .query(parts[0]) }
            return .query("(" + parts.joined(separator: " && ") + ")")

        case .or(let children):
            var parts: [String] = []
            for child in children {
                switch try narrow(child, daystart: daystart) {
                case .unconstrained: return .unconstrained
                case .impossible: continue
                case .query(let q): parts.append(q)
                }
            }
            if parts.isEmpty { return .impossible }
            if parts.count == 1 { return .query(parts[0]) }
            return .query("(" + parts.joined(separator: " || ") + ")")

        case .not:
            // ¬(superset) under-approximates ¬(exact); no sound narrowing.
            return .unconstrained

        case .primary(let primary):
            return try narrowPrimary(primary, daystart: daystart)
        }
    }

    private func narrowPrimary(_ primary: Primary, daystart: Bool) throws -> Narrowing {
        switch primary {
        case .name(let pattern, let caseInsensitive):
            let value = Planner.globQueryValue(pattern)
            if value == "*" {
                // kMDItemFSName == "*" returns NOTHING in fully-indexed trees
                // (verified); only the tier-safe match-all base covers everything.
                return .unconstrained
            }
            let modifier = caseInsensitive ? "c" : ""
            return .query("kMDItemFSName == \"\(value)\"\(modifier)")

        case .time(let field, let arg):
            guard let attribute = Planner.dateAttribute(field) else { return .unconstrained }
            return .query(timeRangeQuery(attribute: attribute, arg: arg, daystart: daystart))

        case .newer(let field, let reference):
            guard let attribute = Planner.dateAttribute(field) else { return .unconstrained }
            let date = try environment.resolveNewerDate(reference)
            return .query("\(attribute) > \(isoTerm(date.addingTimeInterval(-1)))")

        case .user(let name):
            let uid = try environment.resolveUser(name)
            return .query("kMDItemFSOwnerUserID == \(uid)")

        case .group(let name):
            let gid = try environment.resolveGroup(name)
            return .query("kMDItemFSOwnerGroupID == \(gid)")

        case .type(let t):
            switch t {
            case .directory:
                return reducedTier
                    ? .unconstrained : .query("kMDItemContentTypeTree == \"public.folder\"")
            case .regular:
                // != "public.folder" would drop reduced-tier items missing the
                // attribute entirely; no sound narrowing.
                return .unconstrained
            case .symlink, .socket, .fifo, .block, .character, .whiteout:
                // These file kinds are not indexed at all (verified): nothing the
                // index returns can match.
                return .impossible
            }

        case .size(let arg):
            if reducedTier { return .unconstrained }
            // Directories' FSSize does not reliably equal st_size, so they pass
            // through to the post-filter unconditionally.
            let clause: String
            switch arg.unit {
            case .blocks:
                // st_size rounded UP to 512-byte blocks == n  ⟺  size ∈ ((n-1)·512, n·512].
                switch arg.relation {
                case .exactly:
                    clause =
                        "(kMDItemFSSize > \((arg.value - 1) * 512) && kMDItemFSSize <= \(arg.value * 512))"
                case .lessThan:
                    clause = "kMDItemFSSize <= \((arg.value - 1) * 512)"
                case .moreThan:
                    clause = "kMDItemFSSize > \(arg.value * 512)"
                }
            case .bytes(let multiplier):
                let v = arg.value * multiplier
                switch arg.relation {
                case .exactly: clause = "kMDItemFSSize == \(v)"
                case .lessThan: clause = "kMDItemFSSize < \(v)"
                case .moreThan: clause = "kMDItemFSSize > \(v)"
                }
            }
            return .query("(\(clause) || kMDItemContentTypeTree == \"public.folder\")")

        case .empty:
            if reducedTier { return .unconstrained }
            return .query(
                "(kMDItemFSSize == 0 || kMDItemContentTypeTree == \"public.folder\")")

        case .alwaysFalse:
            return .impossible

        // No usable index attribute (verified): path/regex (kMDItemPath is not
        // queryable), atime (kMDItemLastUsedDate ≠ atime), ctime, permissions, inode,
        // links, flags, ACLs, xattrs, fstype, sparseness, hard-link identity, and the
        // access(2) extensions.
        case .path, .lname, .regex, .nouser, .nogroup, .perm, .links, .inum, .samefile,
            .sparse, .flags, .acl, .xattr, .xattrName, .fstype, .readable, .writable,
            .executable, .depth:
            return .unconstrained

        // Constants, actions, traversal, and globals constrain nothing.
        case .alwaysTrue, .print, .print0, .ls, .exec, .delete, .quit, .printf, .prune,
            .global:
            return .unconstrained
        }
    }

    // MARK: - Time math

    static func dateAttribute(_ field: TimeField) -> String? {
        switch field {
        case .modify: return "kMDItemFSContentChangeDate"
        case .birth: return "kMDItemFSCreationDate"
        case .access, .change: return nil
        }
    }

    /// Builds an over-approximating date-range clause for a rounded time comparison.
    /// Verified rounding: day values compare floor(age/86400); minute values compare
    /// ceil(age/60); unit-suffixed values compare raw seconds.
    private func timeRangeQuery(attribute: String, arg: TimeArg, daystart: Bool) -> String {
        let unit: Int64
        var minAge: Int64?
        var maxAge: Int64?
        switch arg.amount {
        case .days(let n):
            unit = 86400
            switch arg.relation {
            case .exactly:
                minAge = n * unit
                maxAge = (n + 1) * unit
            case .lessThan:
                maxAge = n * unit
            case .moreThan:
                minAge = (n + 1) * unit
            }
        case .minutes(let n):
            unit = 60
            switch arg.relation {
            case .exactly:
                minAge = (n - 1) * unit
                maxAge = n * unit
            case .lessThan:
                maxAge = (n - 1) * unit
            case .moreThan:
                minAge = n * unit
            }
        case .seconds(let s):
            unit = 1
            switch arg.relation {
            case .exactly:
                minAge = s
                maxAge = s
            case .lessThan:
                maxAge = s
            case .moreThan:
                minAge = s
            }
        }
        // ±1s absorbs the ISO term's second granularity; -daystart shifts boundaries
        // by up to a day, absorbed by widening rather than day arithmetic.
        let margin: Int64 = 1 + (daystart ? 86400 : 0)
        var parts: [String] = []
        if let maxAge {
            let bound = environment.now.addingTimeInterval(TimeInterval(-(maxAge + margin)))
            parts.append("\(attribute) > \(isoTerm(bound))")
        }
        if let minAge {
            let bound = environment.now.addingTimeInterval(TimeInterval(-(minAge - margin)))
            parts.append("\(attribute) < \(isoTerm(bound))")
        }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " && ") + ")"
    }

    private func isoTerm(_ date: Date) -> String {
        "$time.iso(\(Planner.isoFormatter.string(from: date)))"
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    // MARK: - Glob translation

    /// Converts an fnmatch pattern into an over-approximating MDQuery wildcard value:
    /// only `*` is supported by the query language (verified), so `?`, `[...]`, and
    /// escapes widen to `*`. The result is escaped for embedding in a double-quoted
    /// query literal.
    static func globQueryValue(_ pattern: String) -> String {
        var out = ""
        let chars = Array(pattern)
        var i = 0
        func appendStar() {
            if out.last != "*" { out.append("*") }
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*", "?":
                appendStar()
            case "[":
                // Find the closing bracket per fnmatch rules (leading ! or ^ then an
                // optional literal ]); unterminated classes are literal.
                var j = i + 1
                if j < chars.count && (chars[j] == "!" || chars[j] == "^") { j += 1 }
                if j < chars.count && chars[j] == "]" { j += 1 }
                while j < chars.count && chars[j] != "]" { j += 1 }
                if j < chars.count {
                    appendStar()
                    i = j
                } else {
                    out.append("[")
                }
            case "\\":
                if i + 1 < chars.count {
                    i += 1
                    out.append(chars[i])
                } else {
                    out.append("\\")
                }
            default:
                out.append(c)
            }
            i += 1
        }
        return out.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
