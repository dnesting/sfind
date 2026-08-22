import Darwin
import Foundation

/// Signals -quit: stop all processing immediately (exit status 0).
struct QuitSignal: Error {}

/// The authoritative per-candidate expression evaluator ("the post-filter decides").
/// Serial by design: actions have ordered side effects.
public final class Evaluator {
    let command: ParsedCommand
    let sink: OutputSink
    let nowSeconds: Int64
    let daystartBaseSeconds: Int64?

    private var regexCache: [String: PosixRegex] = [:]
    private var resolvedUsers: [String: UInt32] = [:]
    private var resolvedGroups: [String: UInt32] = [:]
    private var resolvedDates: [Primary: Date] = [:]
    private var resolvedSamefiles: [String: (dev: Int32, ino: UInt64)] = [:]
    private var userTableHits: [UInt32: Bool] = [:]
    private var groupTableHits: [UInt32: Bool] = [:]
    private var execStates: [Primary: ExecState] = [:]
    private var printfWarned: Set<String> = []
    private let promptResponder: ((String) -> Bool)?

    /// Set when any candidate failed to stat (or another non-fatal error occurred);
    /// find's exit status is 1 in that case.
    public private(set) var sawError = false

    public init(
        command: ParsedCommand, environment: PlannerEnvironment, sink: OutputSink,
        promptResponder: ((String) -> Bool)? = nil
    ) throws {
        self.command = command
        self.sink = sink
        self.promptResponder = promptResponder
        self.nowSeconds = Int64(environment.now.timeIntervalSince1970)
        if command.globals.daystart {
            let start = Calendar.current.startOfDay(for: environment.now)
            self.daystartBaseSeconds = Int64(start.timeIntervalSince1970) + 86400
        } else {
            self.daystartBaseSeconds = nil
        }
        try prepare(command.effectiveExpression, environment: environment)
    }

    /// Pre-resolves users/groups/reference dates/regexes so per-candidate evaluation
    /// is cheap, and rejects primaries not implemented yet.
    private func prepare(_ expression: Expression, environment: PlannerEnvironment) throws {
        switch expression {
        case .and(let children), .or(let children):
            for child in children { try prepare(child, environment: environment) }
        case .not(let child):
            try prepare(child, environment: environment)
        case .primary(let primary):
            switch primary {
            case .user(let name):
                resolvedUsers[name] = try environment.resolveUser(name)
            case .group(let name):
                resolvedGroups[name] = try environment.resolveGroup(name)
            case .newer(_, let reference):
                resolvedDates[primary] = try environment.resolveNewerDate(reference)
            case .samefile(let path):
                let info: FileInfo?
                switch command.options.symlinks {
                case .never: info = FileInfo.lstat(path)
                case .commandLine, .always: info = FileInfo.statFollowing(path)
                }
                guard let info else {
                    throw ParseError("\(path): No such file or directory")
                }
                resolvedSamefiles[path] = (info.device, info.inode)
            case .regex(let pattern, let caseInsensitive):
                regexCache[pattern] = try PosixRegex(
                    pattern: pattern,
                    extended: extendedRegexSelected,
                    caseInsensitive: caseInsensitive)
            case .exec(let spec):
                execStates[primary] = ExecState(
                    spec: spec, sink: sink, promptResponder: promptResponder)
            case .delete:
                if command.options.symlinks != .never {
                    throw ParseError("-delete: forbidden when symlinks are followed")
                }
            default:
                break
            }
        }
    }

    private var extendedRegexSelected: Bool {
        if let dialect = command.globals.regexDialect {
            return dialect == .posixExtended
        }
        return command.options.extendedRegex
    }

    // MARK: - Per-candidate evaluation

    public struct Outcome {
        public var matched: Bool
        public var pruned: Bool
        public var isDirectory: Bool
    }

    /// Evaluates the effective expression for one candidate, running actions as they
    /// are reached. Throws QuitSignal on -quit.
    @discardableResult
    public func process(_ candidate: Candidate) throws -> Outcome {
        let skipped = Outcome(matched: false, pruned: false, isDirectory: false)
        // Depth globals apply before the expression.
        if let maxDepth = command.globals.maxDepth, candidate.depth > maxDepth { return skipped }
        if let minDepth = command.globals.minDepth, candidate.depth < minDepth { return skipped }

        var context = Context(candidate: candidate)
        guard statInfo(&context) != nil else {
            if !command.globals.ignoreReaddirRace {
                sink.diagnostic("\(candidate.path): No such file or directory")
                sawError = true
            }
            return skipped
        }
        if command.globals.sameDevice, let rootDevice = candidate.rootDevice,
            let info = statInfo(&context), info.device != rootDevice
        {
            return skipped
        }
        let matched = try evaluate(command.effectiveExpression, &context)
        return Outcome(
            matched: matched, pruned: context.pruneFired,
            isDirectory: statInfo(&context)?.isDirectory ?? false)
    }

    /// Flushes pending -exec … {} + batches; a nonzero child poisons the exit status.
    public func finish() {
        var errored = false
        for state in execStates.values {
            state.flush(sawError: &errored)
            if state.batchFailed { errored = true }
        }
        if errored { sawError = true }
    }

    struct Context {
        var candidate: Candidate
        var info: FileInfo??  // nil = not fetched; .some(nil) = stat failed
        var pruneFired = false
    }

    private func statInfo(_ context: inout Context) -> FileInfo? {
        if let cached = context.info { return cached }
        let path = context.candidate.path
        let info: FileInfo?
        switch command.options.symlinks {
        case .never:
            info = FileInfo.lstat(path)
        case .always:
            info = FileInfo.statFollowing(path)
        case .commandLine:
            // -H follows only command-line operands (depth 0).
            info =
                context.candidate.depth == 0
                ? FileInfo.statFollowing(path) : FileInfo.lstat(path)
        }
        context.info = .some(info)
        return info
    }

    private func evaluate(_ expression: Expression, _ context: inout Context) throws -> Bool {
        switch expression {
        case .and(let children):
            for child in children where try !evaluate(child, &context) {
                return false
            }
            return true
        case .or(let children):
            for child in children where try evaluate(child, &context) {
                return true
            }
            return false
        case .not(let child):
            return try !evaluate(child, &context)
        case .primary(let primary):
            return try evaluatePrimary(primary, &context)
        }
    }

    private func evaluatePrimary(_ primary: Primary, _ context: inout Context) throws -> Bool {
        switch primary {
        case .name(let pattern, let caseInsensitive):
            return fnmatchTest(
                pattern, context.candidate.lastComponent, caseInsensitive: caseInsensitive)

        case .path(let pattern, let caseInsensitive):
            return fnmatchTest(pattern, context.candidate.path, caseInsensitive: caseInsensitive)

        case .lname(let pattern, let caseInsensitive):
            guard let info = statInfo(&context), info.isSymlink else { return false }
            guard let target = readLink(context.candidate.path) else { return false }
            return fnmatchTest(pattern, target, caseInsensitive: caseInsensitive)

        case .regex(let pattern, _):
            guard let regex = regexCache[pattern] else { return false }
            return regex.matchesWholeString(context.candidate.path)

        case .time(let field, let arg):
            guard let info = statInfo(&context) else { return false }
            return timeTest(arg, fileSeconds: Int64(info.timespec(field).tv_sec))

        case .newer(let field, _):
            guard let info = statInfo(&context), let reference = resolvedDates[primary] else {
                return false
            }
            return info.date(field) > reference

        case .user(let name):
            guard let info = statInfo(&context) else { return false }
            return info.uid == resolvedUsers[name]

        case .group(let name):
            guard let info = statInfo(&context) else { return false }
            return info.gid == resolvedGroups[name]

        case .nouser:
            guard let info = statInfo(&context) else { return false }
            if let known = userTableHits[info.uid] { return !known }
            let known = getpwuid(info.uid) != nil
            userTableHits[info.uid] = known
            return !known

        case .nogroup:
            guard let info = statInfo(&context) else { return false }
            if let known = groupTableHits[info.gid] { return !known }
            let known = getgrgid(info.gid) != nil
            groupTableHits[info.gid] = known
            return !known

        case .type(let t):
            guard let info = statInfo(&context) else { return false }
            return info.fileType == t

        case .size(let arg):
            guard let info = statInfo(&context) else { return false }
            switch arg.unit {
            case .blocks:
                // st_size rounded UP to 512-byte blocks (verified).
                return arg.relation.compare((info.size + 511) / 512, to: arg.value)
            case .bytes(let multiplier):
                // Exact bytes, no rounding (verified; differs from GNU).
                return arg.relation.compare(info.size, to: arg.value * multiplier)
            }

        case .perm(let arg):
            guard let info = statInfo(&context) else { return false }
            switch arg.match {
            case .exact: return info.permissionBits == arg.bits
            case .allBits: return info.permissionBits & arg.bits == arg.bits
            case .anyBits: return info.permissionBits & arg.bits != 0
            }

        case .links(let arg):
            guard let info = statInfo(&context) else { return false }
            return arg.relation.compare(Int64(info.linkCount), to: arg.value)

        case .inum(let arg):
            guard let info = statInfo(&context) else { return false }
            return arg.relation.compare(Int64(info.inode), to: arg.value)

        case .samefile(let path):
            guard let info = statInfo(&context), let reference = resolvedSamefiles[path] else {
                return false
            }
            return info.device == reference.dev && info.inode == reference.ino

        case .empty:
            guard let info = statInfo(&context) else { return false }
            if info.isRegular { return info.size == 0 }
            if info.isDirectory { return isEmptyDirectory(context.candidate.path) }
            return false

        case .sparse:
            guard let info = statInfo(&context) else { return false }
            return info.allocatedBlocks * 512 < info.size

        case .flags(let arg):
            guard let info = statInfo(&context) else { return false }
            switch arg.match {
            case .exact:
                return info.flags == arg.flags
            case .allBits:
                return info.flags & arg.flags == arg.flags && info.flags & arg.notflags == 0
            case .anyBits:
                return info.flags & arg.flags != 0 || info.flags & arg.notflags != arg.notflags
            }

        case .acl:
            guard let acl = acl_get_file(context.candidate.path, ACL_TYPE_EXTENDED) else {
                return false
            }
            acl_free(UnsafeMutableRawPointer(acl))
            return true

        case .xattr:
            return listxattr(context.candidate.path, nil, 0, XATTR_NOFOLLOW) > 0

        case .xattrName(let name):
            return getxattr(context.candidate.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0

        case .fstype(let type):
            var fs = statfs()
            guard statfs(context.candidate.path, &fs) == 0 else { return false }
            switch type {
            case "local": return fs.f_flags & UInt32(MNT_LOCAL) != 0
            case "rdonly": return fs.f_flags & UInt32(MNT_RDONLY) != 0
            default:
                return withUnsafeBytes(of: &fs.f_fstypename) { buffer in
                    String(cString: buffer.bindMemory(to: CChar.self).baseAddress!) == type
                }
            }

        case .readable:
            return access(context.candidate.path, R_OK) == 0
        case .writable:
            return access(context.candidate.path, W_OK) == 0
        case .executable:
            return access(context.candidate.path, X_OK) == 0

        case .depth(let arg):
            return arg.relation.compare(Int64(context.candidate.depth), to: arg.value)

        case .prune:
            context.pruneFired = true
            return true

        case .alwaysTrue, .global:
            return true
        case .alwaysFalse:
            return false

        case .print:
            emit(context.candidate.path, terminator: 0x0A)
            return true
        case .print0:
            emit(context.candidate.path, terminator: 0x00)
            return true
        case .quit:
            throw QuitSignal()

        case .ls:
            guard let info = statInfo(&context) else { return false }
            let target = info.isSymlink ? readLink(context.candidate.path) : nil
            sink.write(
                LsFormat.line(
                    path: context.candidate.path, info: info, target: target,
                    nowSeconds: nowSeconds) + "\n")
            return true

        case .printf(let format):
            guard let info = statInfo(&context) else { return false }
            var fs = statfs()
            let fstype: String
            if statfs(context.candidate.path, &fs) == 0 {
                fstype = withUnsafeBytes(of: &fs.f_fstypename) { buffer in
                    String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
                }
            } else {
                fstype = "unknown"
            }
            let input = PrintfFormat.Input(
                path: context.candidate.path, depth: context.candidate.depth, info: info,
                linkTarget: info.isSymlink ? readLink(context.candidate.path) : nil,
                fstype: fstype)
            let (bytes, _) = PrintfFormat.render(format, input: input) { message in
                if printfWarned.insert(message).inserted {
                    sink.diagnostic("-printf: \(message)")
                }
            }
            sink.write(bytes)
            return true

        case .exec:
            guard let state = execStates[primary] else { return false }
            var errored = false
            let result = state.run(path: context.candidate.path, sawError: &errored)
            if errored { sawError = true }
            return result

        case .delete:
            guard let info = statInfo(&context) else { return false }
            let path = context.candidate.path
            let last = context.candidate.lastComponent
            if path == "/" || last == "." || last == ".." {
                sink.diagnostic("-delete: \(path): refusing to delete")
                sawError = true
                return false
            }
            let ok = info.isDirectory ? rmdir(path) == 0 : unlink(path) == 0
            if !ok {
                sink.diagnostic("-delete: \(path): \(String(cString: strerror(errno)))")
                sawError = true
                return false
            }
            return true
        }
    }

    // MARK: - Helpers

    private func emit(_ path: String, terminator: UInt8) {
        if command.options.safeOutput {
            let unsafeChars: Set<Character> = ["'", "\"", "\\", " ", "\t", "\n"]
            if path.contains(where: { unsafeChars.contains($0) }) {
                sink.diagnostic("\(path): skipping, filename contains non-xargs-safe characters")
                return
            }
        }
        var bytes = Array(path.utf8)
        bytes.append(terminator)
        sink.write(bytes)
    }

    private func fnmatchTest(_ pattern: String, _ string: String, caseInsensitive: Bool) -> Bool {
        let flags: Int32 = caseInsensitive ? FNM_CASEFOLD : 0
        return fnmatch(pattern, string, flags) == 0
    }

    /// find's time comparisons (all verified against /usr/bin/find): day values use
    /// floor(age/86400), minute values ceil(age/60), unit-suffixed values raw seconds.
    private func timeTest(_ arg: TimeArg, fileSeconds: Int64) -> Bool {
        let base = daystartBaseSeconds ?? nowSeconds
        let age = base - fileSeconds
        switch arg.amount {
        case .days(let n):
            return arg.relation.compare(age / 86400, to: n)
        case .minutes(let n):
            return arg.relation.compare((age + 59) / 60, to: n)
        case .seconds(let s):
            return arg.relation.compare(age, to: s)
        }
    }

    private func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, Int(PATH_MAX))
        guard n >= 0 else { return nil }
        return String(
            decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func isEmptyDirectory(_ path: String) -> Bool {
        guard let dir = opendir(path) else { return false }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { return false }
        }
        return true
    }
}
