/// A completeness warning: the invocation provably depends on files Spotlight cannot
/// return, so index-backed results may be incomplete. Printed to stderr; never fatal.
public struct PlanWarning: Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }

    static func invisibleType(_ type: FileType) -> PlanWarning {
        let kind: String
        switch type {
        case .symlink: kind = "symlinks"
        case .socket: kind = "sockets"
        case .fifo: kind = "FIFOs"
        case .block: kind = "block devices"
        case .character: kind = "character devices"
        case .whiteout: kind = "whiteouts"
        case .directory, .regular: kind = ""
        }
        return PlanWarning(
            "-type \(type.rawValue) matches only \(kind), which Spotlight does not index; "
                + "results may be incomplete")
    }

    static let symlinkContents = PlanWarning(
        "-lname/-ilname inspect symlinks, which Spotlight does not index; "
            + "results may be incomplete")

    static func dotPattern(_ primary: String, _ pattern: String) -> PlanWarning {
        PlanWarning(
            "\(primary) \(pattern) can only match names starting with a dot, which Spotlight "
                + "does not index; results may be incomplete")
    }

    static func unindexedRoot(_ path: String, reason: String) -> PlanWarning {
        PlanWarning("\(path): \(reason); results may be empty or incomplete")
    }
}
