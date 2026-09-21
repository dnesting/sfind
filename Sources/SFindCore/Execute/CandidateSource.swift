import Foundation

/// A file to be evaluated against the expression.
public struct Candidate: Equatable, Sendable {
    /// The path in find output form (root operand prefix preserved as typed).
    public var path: String
    /// Levels below the root operand it was found under (0 = the operand itself).
    public var depth: Int
    /// st_dev of the root operand, for -x/-xdev.
    public var rootDevice: Int32?
    /// True when the Spotlight index produced this candidate (as opposed to a walk or
    /// a test array). Decides -content terms the query already established.
    public var fromIndex: Bool
    /// The file type readdir(3) reported when a walk produced this candidate, set only
    /// when it equals what the evaluator's own stat would report (so it can stand in
    /// for that stat). Its presence also vouches that the entry existed a moment ago.
    public var direntType: FileType?

    public init(
        path: String, depth: Int, rootDevice: Int32? = nil, fromIndex: Bool = false,
        direntType: FileType? = nil
    ) {
        self.path = path
        self.depth = depth
        self.rootDevice = rootDevice
        self.fromIndex = fromIndex
        self.direntType = direntType
    }

    /// Builds a candidate for `path` found under `root`, deriving depth from the
    /// component count difference.
    public static func under(root: String, path: String, rootDevice: Int32? = nil) -> Candidate {
        let rootComponents = root.split(separator: "/", omittingEmptySubsequences: true).count
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true).count
        return Candidate(
            path: path, depth: max(0, pathComponents - rootComponents), rootDevice: rootDevice)
    }

    public var lastComponent: String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }
}

/// Where candidates come from: MDQuery in production, a plain array in tests (which is
/// what lets full expression semantics be tested with no Spotlight involvement).
/// Sources stream: candidates are delivered as they become available, so output can
/// flow before the search completes.
public protocol CandidateSource {
    /// Calls `body` for each candidate; `body` returns false to stop early (e.g.
    /// -quit). Returns the number of candidates delivered.
    @discardableResult
    func forEachCandidate(_ body: (Candidate) throws -> Bool) throws -> Int

    /// True when producing candidates hit a non-fatal error (an unreadable directory
    /// during a walk); find's exit status becomes 1.
    var sawError: Bool { get }
}

extension CandidateSource {
    public var sawError: Bool { false }

    /// Collects the full candidate list (used when ordering is required: -s, -prune,
    /// -delete).
    public func collect() throws -> [Candidate] {
        var result: [Candidate] = []
        try forEachCandidate { candidate in
            result.append(candidate)
            return true
        }
        return result
    }
}

public struct ArraySource: CandidateSource {
    public var items: [Candidate]

    public init(_ items: [Candidate]) {
        self.items = items
    }

    @discardableResult
    public func forEachCandidate(_ body: (Candidate) throws -> Bool) throws -> Int {
        var delivered = 0
        for item in items {
            delivered += 1
            if try !body(item) { break }
        }
        return delivered
    }
}
