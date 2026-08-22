@preconcurrency import CoreServices
import Darwin
import Foundation

/// A search root: as typed by the user (preserved in output), absolute, canonical
/// (realpath, for mapping index results back), and its device (for -x).
public struct RootScope: Sendable {
    public var typed: String
    public var absolute: String
    public var canonical: String
    public var device: Int32?

    public init(typed: String, followSymlinks: Bool) {
        self.typed = typed
        var absolute = typed
        if !typed.hasPrefix("/") {
            absolute = FileManager.default.currentDirectoryPath + "/" + typed
        }
        // Expand a leading tilde: MDQuerySetSearchScope does not (verified).
        if typed.hasPrefix("~") {
            absolute = NSString(string: typed).expandingTildeInPath
        }
        self.absolute = absolute
        if let resolved = realpath(absolute, nil) {
            self.canonical = String(cString: resolved)
            free(resolved)
        } else {
            self.canonical = absolute
        }
        let info = followSymlinks ? FileInfo.statFollowing(typed) : FileInfo.lstat(typed)
        self.device = info?.device
    }

    /// True when the root itself is a hidden directory (reduced index tier).
    public var isHidden: Bool {
        canonical.split(separator: "/").last?.hasPrefix(".") ?? false
    }

    /// True when the root sits INSIDE a hidden directory (index scoping to such paths
    /// is unreliable — verified).
    public var isInsideHiddenDirectory: Bool {
        let components = canonical.split(separator: "/")
        return components.dropLast().contains { $0.hasPrefix(".") }
    }

    /// If an exclusion marker makes this root invisible to Spotlight, returns the
    /// directory carrying the .metadata_never_index marker (or the .noindex ancestor).
    /// This is a cheap O(path depth) stat walk up the ancestors — no directory scan.
    public var exclusionMarkerDirectory: String? {
        var dir = canonical
        while true {
            if FileManager.default.fileExists(atPath: dir + "/.metadata_never_index") {
                return dir
            }
            guard let slash = dir.lastIndex(of: "/"), slash != dir.startIndex else { break }
            dir = String(dir[..<slash])
        }
        var prefix = ""
        for component in canonical.split(separator: "/") {
            prefix += "/" + component
            if component.hasSuffix(".noindex") {
                return prefix
            }
        }
        return nil
    }
}

private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Runs the planned MDQuery over the given scopes, streaming candidates as the index
/// delivers result batches (asynchronous execution + progress notifications), with
/// output paths mapped back onto the user's typed roots.
public final class MDQuerySource: CandidateSource {
    public let queryString: String?
    public let roots: [RootScope]
    /// Results the index itself returned (excludes the seeded roots). The
    /// authoritative "did the index have anything for us" signal.
    public private(set) var indexResultCount = 0

    // Streaming state, valid only during forEachCandidate.
    private var query: MDQuery?
    private var processed = 0
    private var seen = Set<String>()
    private var orderedRoots: [RootScope] = []
    private var body: ((Candidate) throws -> Bool)?
    private var delivered = 0
    private var stopped = false
    private var failure: Error?

    public init(queryString: String?, roots: [RootScope]) {
        self.queryString = queryString
        self.roots = roots
    }

    @discardableResult
    public func forEachCandidate(_ body: (Candidate) throws -> Bool) throws -> Int {
        // The scope query never returns the roots themselves; find prints a root when
        // it matches, so seed them explicitly (the post-filter decides anyway).
        seen.removeAll()
        delivered = 0
        stopped = false
        failure = nil
        processed = 0
        indexResultCount = 0
        for root in roots where seen.insert(root.typed).inserted {
            delivered += 1
            if try !body(Candidate(path: root.typed, depth: 0, rootDevice: root.device)) {
                return delivered
            }
        }
        guard let queryString, !roots.isEmpty else { return delivered }

        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil)
        else {
            throw ParseError("failed to create Spotlight query: \(queryString)")
        }
        self.query = query
        defer { self.query = nil }
        MDQuerySetSearchScope(query, roots.map(\.absolute) as CFArray, 0)
        // Small first batch for fast time-to-first-result, then larger batches.
        let batching = MDQueryBatchingParams(
            first_max_num: 64, first_max_ms: 50,
            progress_max_num: 2048, progress_max_ms: 100,
            update_max_num: 0, update_max_ms: 0)
        MDQuerySetBatchingParameters(query, batching)
        orderedRoots = roots.sorted { $0.canonical.count > $1.canonical.count }

        // Progress/finish notifications arrive on this thread's run loop; each batch
        // is drained and streamed to `body` while the query keeps gathering.
        let center = CFNotificationCenterGetLocalCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer else { return }
            let source = Unmanaged<MDQuerySource>.fromOpaque(observer).takeUnretainedValue()
            source.handleNotification(name: name?.rawValue as String?)
        }
        for name in [kMDQueryProgressNotification!, kMDQueryDidFinishNotification!] {
            CFNotificationCenterAddObserver(
                center, observer, callback, name as CFString,
                Unmanaged.passUnretained(query).toOpaque(),
                .deliverImmediately)
        }
        defer { CFNotificationCenterRemoveEveryObserver(center, observer) }

        try withoutActuallyEscaping(body) { escapableBody in
            self.body = escapableBody
            defer { self.body = nil }
            guard MDQueryExecute(query, 0) else {
                throw ParseError("Spotlight query failed to execute")
            }
            CFRunLoopRun()
            if let failure {
                self.failure = nil
                throw failure
            }
        }
        return delivered
    }

    private func handleNotification(name: String?) {
        guard let query, let body else { return }
        MDQueryDisableUpdates(query)
        defer { MDQueryEnableUpdates(query) }

        let total = MDQueryGetResultCount(query)
        if total > processed, !stopped {
            var items: [MDItem] = []
            items.reserveCapacity(total - processed)
            for i in processed..<total {
                if let pointer = MDQueryGetResultAtIndex(query, i) {
                    items.append(Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue())
                }
            }
            processed = total
            indexResultCount = total
            for path in Self.copyPaths(items) {
                guard let path, seen.insert(path).inserted else { continue }
                guard let candidate = Self.map(path: path, roots: orderedRoots) else { continue }
                delivered += 1
                do {
                    if try !body(candidate) {
                        stopped = true
                        break
                    }
                } catch {
                    failure = error
                    stopped = true
                    break
                }
            }
        }
        if stopped {
            MDQueryStop(query)
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        if name == (kMDQueryDidFinishNotification! as String) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    /// Authoritative per-root probe: does the index hold ANYTHING under this root?
    /// Used to explain empty results accurately even when heuristics (markers, hidden
    /// dirs) would guess wrong in either direction.
    public static func indexHasAnyEntry(under root: RootScope) -> Bool {
        guard
            let query = MDQueryCreate(
                kCFAllocatorDefault, QueryPlan.matchAll as CFString, nil, nil)
        else { return false }
        MDQuerySetSearchScope(query, [root.absolute] as CFArray, 0)
        MDQuerySetMaxCount(query, 1)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return false
        }
        return MDQueryGetResultCount(query) > 0
    }

    /// kMDItemPath is computed on demand, never stored, so the batched
    /// MDItemsCopyAttributes returns null for it (verified) — fetch per item, in
    /// parallel chunks to amortize the per-item IPC.
    private static func copyPaths(_ items: [MDItem]) -> [String?] {
        guard !items.isEmpty else { return [] }
        let chunkSize = 512
        let chunkCount = (items.count + chunkSize - 1) / chunkSize
        var paths = [String?](repeating: nil, count: items.count)
        paths.withUnsafeMutableBufferPointer { buffer in
            let base = UnsafeSendableBox(value: buffer.baseAddress!)
            let boxedItems = UnsafeSendableBox(value: items)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let lower = chunk * chunkSize
                let upper = min(lower + chunkSize, boxedItems.value.count)
                for i in lower..<upper {
                    base.value[i] =
                        MDItemCopyAttribute(boxedItems.value[i], kMDItemPath) as? String
                }
            }
        }
        return paths
    }

    /// Maps an index result path onto the typed root it belongs to, producing the
    /// find-style output path and depth. Handles the /System/Volumes/Data firmlink
    /// prefix the raw kMDItemPath carries (verified).
    static func map(path: String, roots: [RootScope]) -> Candidate? {
        let dataPrefix = "/System/Volumes/Data"
        var forms = [path]
        if path.hasPrefix(dataPrefix + "/") {
            forms.append(String(path.dropFirst(dataPrefix.count)))
        }
        for root in roots {
            var prefixes = [root.canonical]
            if !root.canonical.hasPrefix(dataPrefix) {
                prefixes.append(dataPrefix + root.canonical)
            }
            for form in forms {
                for prefix in prefixes {
                    if form == prefix {
                        return Candidate(path: root.typed, depth: 0, rootDevice: root.device)
                    }
                    if form.hasPrefix(prefix + "/") {
                        let relative = String(form.dropFirst(prefix.count + 1))
                        let depth = relative.split(separator: "/").count
                        let typedBase =
                            root.typed.hasSuffix("/")
                            ? String(root.typed.dropLast()) : root.typed
                        return Candidate(
                            path: typedBase + "/" + relative, depth: depth,
                            rootDevice: root.device)
                    }
                }
            }
        }
        return nil
    }
}
