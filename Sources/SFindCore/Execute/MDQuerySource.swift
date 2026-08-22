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

/// Runs the planned MDQuery over the given scopes and yields candidates with output
/// paths mapped back onto the user's typed roots.
public struct MDQuerySource: CandidateSource {
    public var queryString: String?
    public var roots: [RootScope]

    public init(queryString: String?, roots: [RootScope]) {
        self.queryString = queryString
        self.roots = roots
    }

    public func candidates() throws -> [Candidate] {
        // The scope query never returns the roots themselves; find prints a root when
        // it matches, so seed them explicitly (the post-filter decides anyway).
        var seen = Set<String>()
        var result: [Candidate] = []
        for root in roots {
            if seen.insert(root.typed).inserted {
                result.append(Candidate(path: root.typed, depth: 0, rootDevice: root.device))
            }
        }
        guard let queryString, !roots.isEmpty else { return result }

        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil)
        else {
            throw ParseError("failed to create Spotlight query: \(queryString)")
        }
        MDQuerySetSearchScope(query, roots.map(\.absolute) as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw ParseError("Spotlight query failed to execute")
        }

        let count = MDQueryGetResultCount(query)
        var items: [MDItem] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            if let pointer = MDQueryGetResultAtIndex(query, i) {
                items.append(Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue())
            }
        }
        // Longest canonical prefix wins when roots overlap.
        let orderedRoots = roots.sorted { $0.canonical.count > $1.canonical.count }
        for path in Self.copyPaths(items) {
            guard let path, seen.insert(path).inserted else { continue }
            if let candidate = Self.map(path: path, roots: orderedRoots) {
                result.append(candidate)
            }
        }
        return result
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
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let lower = chunk * chunkSize
                let upper = min(lower + chunkSize, items.count)
                for i in lower..<upper {
                    base[i] = MDItemCopyAttribute(items[i], kMDItemPath) as? String
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
