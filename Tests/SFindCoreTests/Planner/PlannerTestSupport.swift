import Foundation
import SFindCore

/// Deterministic planner environment: now = 2026-01-02T00:00:00Z, david/staff resolve to
/// 501/20, and -newer references resolve to 2026-01-01T00:00:00Z.
enum PlannerFixtures {
    static let now: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-01-02T00:00:00Z")!
    }()

    static let newerReferenceDate: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-01-01T00:00:00Z")!
    }()

    static let environment = PlannerEnvironment(
        now: now,
        resolveUser: { name in
            if name == "david" { return 501 }
            if let uid = UInt32(name) { return uid }
            throw ParseError("-user: \(name): no such user")
        },
        resolveGroup: { name in
            if name == "staff" { return 20 }
            if let gid = UInt32(name) { return gid }
            throw ParseError("-group: \(name): no such group")
        },
        resolveNewerDate: { _ in newerReferenceDate })

    static func plan(_ tokens: [String], reducedTier: Bool = false) throws -> QueryPlan {
        let command = try CommandParser().parse(["."] + tokens)
        return try Planner(environment: environment, reducedTier: reducedTier).plan(command)
    }

    static func query(_ tokens: String...) throws -> String? {
        try plan(tokens).queryString
    }
}
