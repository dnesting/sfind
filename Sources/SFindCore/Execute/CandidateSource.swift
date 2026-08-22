import Foundation

/// A file to be evaluated against the expression.
public struct Candidate: Equatable, Sendable {
    /// The path in find output form (root operand prefix preserved as typed).
    public var path: String
    /// Levels below the root operand it was found under (0 = the operand itself).
    public var depth: Int
    /// st_dev of the root operand, for -x/-xdev.
    public var rootDevice: Int32?

    public init(path: String, depth: Int, rootDevice: Int32? = nil) {
        self.path = path
        self.depth = depth
        self.rootDevice = rootDevice
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
public protocol CandidateSource {
    func candidates() throws -> [Candidate]
}

public struct ArraySource: CandidateSource {
    public var items: [Candidate]

    public init(_ items: [Candidate]) {
        self.items = items
    }

    public func candidates() throws -> [Candidate] {
        items
    }
}
