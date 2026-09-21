import Darwin
import Foundation

/// A search root for the walker. `exhaustive` roots yield every entry (a plain find
/// traversal); the others yield only what Spotlight does not index, leaving the rest
/// to the index query over the same root.
public struct WalkRoot: Sendable {
    public var scope: RootScope
    public var exhaustive: Bool

    public init(scope: RootScope, exhaustive: Bool) {
        self.scope = scope
        self.exhaustive = exhaustive
    }
}

public struct WalkOptions: Sendable {
    public var symlinks: SymlinkMode = .never
    public var maxDepth: Int? = nil
    public var sameDevice = false
    /// -d: yield a directory after its contents.
    public var depthFirst = false
    /// Paths already delivered by an earlier phase; never yielded again.
    public var skip: Set<String> = []
    /// Stop after yielding this many candidates (the small-scope shortcut's budget).
    public var limit: Int? = nil
    /// Stop once this many seconds have elapsed (checked per directory).
    public var timeLimit: Double? = nil
    /// Every directory the index holds under the roots (candidate path form). When
    /// set, a directory missing from it starts a gap subtree and is yielded itself —
    /// the authoritative way to catch exclusions the name rules cannot see (Spotlight
    /// privacy entries, unindexed volumes, system policy such as most of ~/Library).
    public var indexedDirectories: Set<String>? = nil

    public init() {}
}

/// Directory traversal that yields candidates in find's pre-order (or post-order under
/// -d) using readdir(3) type information, so non-gap regular files cost no lstat.
///
/// Gap classification, relative to each root: an entry is a gap when its name starts
/// with a dot, when it is anything but a regular file or directory (symlinks, FIFOs,
/// sockets, devices, whiteouts), or when it lies under a gap subtree — a dot
/// directory, a `*.noindex` directory, a directory carrying `.metadata_never_index`,
/// or a package (bundle) directory. Everything else is the index's job. Whether a
/// root itself is covered by the index is the caller's determination (`exhaustive`).
public final class Walker {
    public enum Outcome: Equatable {
        case completed
        case limitReached
        case stopped
    }

    /// Consulted for each directory candidate before descending (pre-order only);
    /// false skips its subtree. Used to honor -prune without reading pruned trees.
    public var shouldDescend: ((Candidate) -> Bool)?
    /// Receives traversal errors (unreadable directories), find-style.
    public var diagnostic: ((String) -> Void)?
    public private(set) var sawError = false
    /// Candidate paths yielded so far, tracked only when a limit or time limit is set
    /// so a later phase can skip them.
    public private(set) var emitted = Set<String>()
    public private(set) var yielded = 0

    private let roots: [WalkRoot]
    private let options: WalkOptions
    private let progress: Progress?
    private let clock: () -> Double

    public init(
        roots: [WalkRoot], options: WalkOptions, progress: Progress? = nil,
        clock: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.roots = roots
        self.options = options
        self.progress = progress
        self.clock = clock
    }

    private struct Entry {
        var name: String
        var type: UInt8
    }

    private struct Frame {
        var path: String
        var depth: Int
        var entries: [Entry]
        var index = 0
        /// Yield every entry (exhaustive root or gap subtree).
        var emitAll: Bool
        /// Progress weight of one entry of this frame (product of 1/count up the stack).
        var unitWeight: Double
        /// Under -d, the directory candidate to yield once its contents are done.
        var deferred: Candidate?
        /// (dev, ino) when following symlinks, for cycle detection.
        var identity: (dev: Int32, ino: UInt64)?
    }

    private var tracksEmitted: Bool { options.limit != nil || options.timeLimit != nil }

    /// Walks every root, calling `body` per candidate; `body` returns false to stop.
    @discardableResult
    public func run(_ body: (Candidate) throws -> Bool) throws -> Outcome {
        let deadline = options.timeLimit.map { clock() + $0 }
        var rootProgress = 0.0
        for (rootIndex, root) in roots.enumerated() {
            rootProgress = Double(rootIndex) / Double(roots.count)
            let rootWeight = 1.0 / Double(roots.count)
            let scope = root.scope
            let rootPath = scope.typed
            let rootCandidate = Candidate(
                path: rootPath, depth: scope.depthOffset, rootDevice: scope.device)
            let info =
                options.symlinks == .never
                ? FileInfo.lstat(rootPath) : FileInfo.statFollowing(rootPath)
            let isDirectory = info?.isDirectory ?? false
            var stack: [Frame] = []
            if root.exhaustive, !options.depthFirst {
                if try !yield(rootCandidate, body) { return .stopped }
                if let outcome = limitOutcome(deadline: deadline) { return outcome }
            }
            var descend = isDirectory
            if descend, let maxDepth = options.maxDepth, scope.depthOffset >= maxDepth {
                descend = false
            }
            if descend, root.exhaustive, !options.depthFirst, let shouldDescend,
                !shouldDescend(rootCandidate)
            {
                descend = false
            }
            if descend, let entries = read(rootPath) {
                stack.append(
                    Frame(
                        path: rootPath, depth: scope.depthOffset, entries: entries,
                        emitAll: root.exhaustive || Walker.isGapSubtree(entries: entries),
                        unitWeight: rootWeight / Double(max(entries.count, 1)),
                        deferred: root.exhaustive && options.depthFirst ? rootCandidate : nil,
                        identity: options.symlinks == .always
                            ? info.map { ($0.device, $0.inode) } : nil))
            } else if root.exhaustive, options.depthFirst {
                if try !yield(rootCandidate, body) { return .stopped }
            }

            while var frame = stack.popLast() {
                if frame.index >= frame.entries.count {
                    if let deferred = frame.deferred {
                        if try !yield(deferred, body) { return .stopped }
                        if let outcome = limitOutcome(deadline: deadline) { return outcome }
                    }
                    continue
                }
                let entry = frame.entries[frame.index]
                frame.index += 1
                progress?.counters.scanned += 1
                stack.append(frame)
                progress?.setFraction(rootProgress + Walker.fraction(of: stack))

                let path =
                    frame.path.hasSuffix("/")
                    ? frame.path + entry.name : frame.path + "/" + entry.name
                let depth = frame.depth + 1
                if let maxDepth = options.maxDepth, depth > maxDepth { continue }

                var type = entry.type
                var lstatInfo: FileInfo?
                if type == UInt8(DT_UNKNOWN) {
                    lstatInfo = FileInfo.lstat(path)
                    type = Walker.direntType(of: lstatInfo)
                }
                let isDot = entry.name.hasPrefix(".")
                let isSpecial = type != UInt8(DT_DIR) && type != UInt8(DT_REG)
                let unindexedDirectory =
                    type == UInt8(DT_DIR) && !frame.emitAll && !isDot
                    && (options.indexedDirectories.map { !$0.contains(path) } ?? false)
                let isGap = frame.emitAll || isDot || isSpecial || unindexedDirectory
                // Below the root the evaluator lstat's (or, under -L, stats — which
                // agrees with lstat for everything but symlinks), so readdir's type
                // can stand in for it and spare the stat entirely.
                let trustedType =
                    options.symlinks == .always && type == UInt8(DT_LNK)
                    ? nil : Walker.fileType(of: type)
                let candidate = Candidate(
                    path: path, depth: depth, rootDevice: root.scope.device,
                    direntType: trustedType)

                // Directory to descend into: a real directory, or a symlink to one when
                // symlinks are followed (-L everywhere; -H only at the root, which is
                // handled above).
                var directoryInfo: FileInfo?
                if type == UInt8(DT_DIR) {
                    // Only -x and -L need the directory's own stat (device / identity).
                    if options.sameDevice || options.symlinks == .always {
                        directoryInfo = lstatInfo ?? FileInfo.lstat(path)
                    }
                } else if type == UInt8(DT_LNK), options.symlinks == .always,
                    let target = FileInfo.statFollowing(path), target.isDirectory
                {
                    directoryInfo = target
                }
                let isDirectory = type == UInt8(DT_DIR) || directoryInfo != nil

                let deliver = isGap && !options.skip.contains(path)
                var deferred: Candidate?
                if deliver {
                    if options.depthFirst && isDirectory {
                        deferred = candidate
                    } else {
                        if try !yield(candidate, body) { return .stopped }
                        if let outcome = limitOutcome(deadline: deadline) { return outcome }
                    }
                }

                guard isDirectory else { continue }
                if let maxDepth = options.maxDepth, depth >= maxDepth {
                    if let deferred, try !yield(deferred, body) { return .stopped }
                    continue
                }
                if options.sameDevice, let device = root.scope.device,
                    let info = directoryInfo, info.device != device
                {
                    if let deferred, try !yield(deferred, body) { return .stopped }
                    continue
                }
                if deliver, !options.depthFirst, let shouldDescend, !shouldDescend(candidate) {
                    continue
                }
                var identity: (dev: Int32, ino: UInt64)?
                if options.symlinks == .always, let info = directoryInfo {
                    identity = (info.device, info.inode)
                    if stack.contains(where: {
                        $0.identity?.dev == info.device && $0.identity?.ino == info.inode
                    }) {
                        // A symlink cycle: find reports it and does not descend.
                        report("\(path): Filesystem loop detected")
                        if let deferred, try !yield(deferred, body) { return .stopped }
                        continue
                    }
                }
                guard let entries = read(path) else {
                    if let deferred, try !yield(deferred, body) { return .stopped }
                    continue
                }
                let emitAll =
                    frame.emitAll || isDot || unindexedDirectory
                    || entry.name.hasSuffix(".noindex")
                    || Walker.isGapSubtree(entries: entries)
                    || (entry.name.contains(".") && Walker.isPackage(path))
                stack.append(
                    Frame(
                        path: path, depth: depth, entries: entries, emitAll: emitAll,
                        unitWeight: frame.unitWeight / Double(max(entries.count, 1)),
                        deferred: deferred, identity: identity))
                if let deadline, clock() >= deadline, tracksEmitted { return .limitReached }
            }
        }
        progress?.setFraction(1)
        return .completed
    }

    private func yield(_ candidate: Candidate, _ body: (Candidate) throws -> Bool) throws -> Bool {
        yielded += 1
        if tracksEmitted { emitted.insert(candidate.path) }
        return try body(candidate)
    }

    private func limitOutcome(deadline: Double?) -> Outcome? {
        if let limit = options.limit, yielded >= limit { return .limitReached }
        if let deadline, clock() >= deadline { return .limitReached }
        return nil
    }

    private func report(_ message: String) {
        sawError = true
        diagnostic?(message)
    }

    /// Reads a directory's entries (excluding . and ..), reporting failures find-style.
    private func read(_ path: String) -> [Entry]? {
        guard let dir = opendir(path) else {
            report("\(path): \(String(cString: strerror(errno)))")
            return nil
        }
        defer { closedir(dir) }
        var entries: [Entry] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            entries.append(Entry(name: name, type: entry.pointee.d_type))
        }
        progress?.tick()
        return entries
    }

    /// A directory whose listing carries the Spotlight exclusion marker.
    private static func isGapSubtree(entries: [Entry]) -> Bool {
        entries.contains { $0.name == ".metadata_never_index" }
    }

    /// Package (bundle) directories are indexed as single items; their contents are not.
    static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage)
            ?? false
    }

    private static func fileType(of direntType: UInt8) -> FileType? {
        switch Int32(direntType) {
        case DT_DIR: return .directory
        case DT_REG: return .regular
        case DT_LNK: return .symlink
        case DT_FIFO: return .fifo
        case DT_SOCK: return .socket
        case DT_CHR: return .character
        case DT_BLK: return .block
        case DT_WHT: return .whiteout
        default: return nil
        }
    }

    private static func direntType(of info: FileInfo?) -> UInt8 {
        switch info?.fileType {
        case .directory?: return UInt8(DT_DIR)
        case .regular?: return UInt8(DT_REG)
        case .symlink?: return UInt8(DT_LNK)
        case .fifo?: return UInt8(DT_FIFO)
        case .socket?: return UInt8(DT_SOCK)
        case .character?: return UInt8(DT_CHR)
        case .block?: return UInt8(DT_BLK)
        case .whiteout?: return UInt8(DT_WHT)
        case nil: return UInt8(DT_UNKNOWN)
        }
    }

    /// Hierarchical completion estimate for a DFS position: each frame contributes the
    /// entries it has fully consumed, each weighted by the frame's share of the whole
    /// (every directory is assumed to hold equal work — best effort, monotonic).
    private static func fraction(of stack: [Frame]) -> Double {
        var total = 0.0
        for frame in stack {
            // frame.index is one past the entry being processed.
            total += Double(max(frame.index - 1, 0)) * frame.unitWeight
        }
        return min(total, 1)
    }
}
