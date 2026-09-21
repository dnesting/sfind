import Foundation

/// A directory name that every match of a -path/-ipath/-regex/-iregex pattern must
/// have as an ancestor component: a `/name/` run in the pattern with no metacharacters
/// inside and none that could make it optional around it. Such an anchor lets the index
/// enumerate the candidate subtrees (`kMDItemFSName == name` directories) so both the
/// query and any walk cover only those subtrees instead of the whole scope.
public struct PathAnchor: Hashable, Sendable {
    public var name: String
    public var caseInsensitive: Bool

    public init(name: String, caseInsensitive: Bool) {
        self.name = name
        self.caseInsensitive = caseInsensitive
    }

    /// Anchors implied by an fnmatch(3) pattern as -path applies it (`/` is an
    /// ordinary character, `*` and `?` match it). Conservative: nothing is derived
    /// past the first `[` or `\` because a bracket expression or escape before the run
    /// could swallow one of its slashes.
    public static func anchors(fnmatch pattern: String, caseInsensitive: Bool) -> [PathAnchor] {
        literalRuns(in: pattern, metacharacters: "*?[]\\", stopAt: "[\\", quantifiers: "")
            .map { PathAnchor(name: $0, caseInsensitive: caseInsensitive) }
    }

    /// Anchors implied by a POSIX regular expression (BRE or ERE), which -regex
    /// anchors at both ends over the whole path. Any grouping, alternation, or interval
    /// syntax disables derivation (a group could be optional); a quantifier following
    /// the closing slash makes that slash optional, so such runs are rejected.
    public static func anchors(regex pattern: String, caseInsensitive: Bool) -> [PathAnchor] {
        if pattern.contains(where: { "(){}|".contains($0) }) { return [] }
        return literalRuns(
            in: pattern, metacharacters: ".*?+^$\\[]", stopAt: "[\\", quantifiers: "*?+"
        ).map { PathAnchor(name: $0, caseInsensitive: caseInsensitive) }
    }

    /// Every `/run/` in `pattern` whose run is non-empty and free of `metacharacters`,
    /// appears before any character in `stopAt`, and whose closing slash is not
    /// followed by a character in `quantifiers`. Runs may share a slash (`/a/b/`).
    private static func literalRuns(
        in pattern: String, metacharacters: String, stopAt: String, quantifiers: String
    ) -> [String] {
        let chars = Array(pattern)
        var runs: [String] = []
        var start = 0
        while start < chars.count {
            if stopAt.contains(chars[start]) { break }
            guard chars[start] == "/" else {
                start += 1
                continue
            }
            var end = start + 1
            while end < chars.count, chars[end] != "/" {
                if stopAt.contains(chars[end]) { return runs }
                end += 1
            }
            guard end < chars.count else { break }
            let run = String(chars[(start + 1)..<end])
            let next = end + 1 < chars.count ? chars[end + 1] : nil
            if !run.isEmpty, !run.contains(where: { metacharacters.contains($0) }),
                next.map({ !quantifiers.contains($0) }) ?? true, !runs.contains(run)
            {
                runs.append(run)
            }
            start = end
        }
        return runs
    }

    /// True when a root typed as `typed` already contains the anchor as one of its own
    /// components (or is named by it): everything under that root then satisfies the
    /// anchor, so it cannot narrow the scope.
    public func isSatisfied(byRootTyped typed: String) -> Bool {
        let base = typed.hasSuffix("/") && typed != "/" ? String(typed.dropLast()) : typed
        let haystack = (base.hasPrefix("/") ? base : "/" + base) + "/"
        if caseInsensitive {
            return haystack.lowercased().contains("/" + name.lowercased() + "/")
        }
        return haystack.contains("/" + name + "/")
    }
}
