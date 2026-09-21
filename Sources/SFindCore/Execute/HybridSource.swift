import Foundation

/// The production candidate source: the Spotlight index query, optionally
/// supplemented (or replaced) by a filesystem walk per `--walk`, with the search
/// scope refined through index-found anchor directories when the expression allows.
///
/// Phases, each streaming candidates to the caller:
///
/// 1. **Exhaustive prefix** (walk modes): a plain walk of the roots under a small
///    budget. Small scopes finish here and never pay the index's IPC floor. Otherwise
///    the paths it delivered are excluded from the later phases.
/// 2. **Index** (unless `--walk=only`): the planned MDQuery over the roots the index
///    covers — refined to anchor subtrees when a top-level `-path`/`-regex` conjunct
///    names a literal component and either a walk follows or the query would
///    otherwise return the whole scope.
/// 3. **Gap walk** (walk modes): the same roots, yielding only what the index does
///    not hold (guided by the index's own folder list); roots the index has nothing
///    for are walked exhaustively instead.
public final class HybridSource: CandidateSource {
    /// Candidates the exhaustive prefix may deliver before deferring to the index.
    public static let exhaustiveBudget = 8192
    /// Seconds the exhaustive prefix may run (cold caches make entry counts a poor
    /// proxy for time).
    public static let exhaustiveTimeBudget = 0.15

    public let command: ParsedCommand
    public let plan: QueryPlan
    public let roots: [RootScope]
    public var shouldDescend: ((Candidate) -> Bool)?
    public private(set) var sawError = false
    /// Results the index itself returned across the run.
    public private(set) var indexResultCount = 0
    /// Whether the index query ran at all (a completed exhaustive prefix skips it).
    public private(set) var usedIndex = false
    /// The roots the index query ran over (refined ones when an anchor applied).
    public private(set) var indexRoots: [RootScope] = []

    private let sink: OutputSink
    private let progress: Progress?
    private let debug: DebugLog?
    private var gapSubtreesLogged = 0

    public init(
        command: ParsedCommand, plan: QueryPlan, roots: [RootScope], sink: OutputSink,
        progress: Progress? = nil, debug: DebugLog? = nil
    ) {
        self.command = command
        self.plan = plan
        self.roots = roots
        self.sink = sink
        self.progress = progress
        self.debug = debug
    }

    @discardableResult
    public func forEachCandidate(_ body: (Candidate) throws -> Bool) throws -> Int {
        var delivered = 0
        var stopped = false
        func deliver(_ candidate: Candidate) throws -> Bool {
            delivered += 1
            if try !body(candidate) {
                stopped = true
                return false
            }
            return true
        }

        let mode = command.options.walk
        var skip = Set<String>()

        // Phase 1: exhaustive prefix (or the entire walk under --walk=only).
        if mode.walks {
            var options = walkOptions()
            if mode.usesIndex {
                options.limit = HybridSource.exhaustiveBudget
                options.timeLimit = HybridSource.exhaustiveTimeBudget
            }
            let walker = makeWalker(
                roots: roots.map { WalkRoot(scope: $0, exhaustive: true) }, options: options)
            let started = Date()
            if mode.usesIndex {
                debug?.log(
                    "walk mode \(mode.rawValue): exhaustive walk of "
                        + "\(DebugLog.count(roots.count, "root")) first, budget "
                        + "\(HybridSource.exhaustiveBudget) candidates or "
                        + "\(Int(HybridSource.exhaustiveTimeBudget * 1000)) ms")
            } else {
                debug?.log(
                    "walk mode only: plain walk of \(DebugLog.count(roots.count, "root")), "
                        + "the index is not consulted")
            }
            progress?.setPhase("walking", fraction: 0)
            let outcome = try walker.run(deliver)
            if let debug {
                let verdict: String
                switch outcome {
                case .completed: verdict = "scope exhausted, index not needed"
                case .limitReached: verdict = "budget reached, continuing with the index"
                case .stopped: verdict = "stopped early (-quit or closed output)"
                }
                debug.log(
                    "exhaustive walk: scanned \(DebugLog.count(walker.scanned, "entry", "entries")), "
                        + "yielded \(DebugLog.count(walker.yielded, "candidate")) in "
                        + "\(debug.elapsed(since: started)); \(verdict)")
            }
            if outcome != .limitReached { return delivered }
            skip = walker.emitted
        }
        guard mode.usesIndex else { return delivered }

        // Which roots the index covers at all (only worth asking when a walk can
        // take over the others).
        var indexedRoots = roots
        var unindexedRoots: [RootScope] = []
        if mode.walks {
            indexedRoots = []
            for root in roots {
                if let marker = root.exclusionMarkerDirectory {
                    debug?.log(
                        "root '\(root.typed)': excluded from the index (\(marker) carries a "
                            + ".metadata_never_index marker or .noindex name); walked exhaustively")
                    unindexedRoots.append(root)
                } else if !MDQuerySource.indexHasAnyEntry(under: root) {
                    debug?.log(
                        "root '\(root.typed)': the index holds nothing under it; "
                            + "walked exhaustively")
                    unindexedRoots.append(root)
                } else {
                    debug?.log("root '\(root.typed)': indexed (probe found entries)")
                    indexedRoots.append(root)
                }
            }
        }

        // Anchor refinement: query the index for the anchor directories and make
        // them the roots of everything that follows.
        var queryRoots = indexedRoots
        if !indexedRoots.isEmpty, plan.queryString != nil, mode.walks || plan.isMatchAll,
            let anchor = plan.anchors.first(where: { anchor in
                !roots.contains { anchor.isSatisfied(byRootTyped: $0.typed) }
            })
        {
            let started = Date()
            let (query, refined) = HybridSource.refine(indexedRoots, by: anchor)
            queryRoots = refined
            debug?.log(
                "path anchor '\(anchor.name)': \(query) over "
                    + "\(DebugLog.count(indexedRoots.count, "root")) → "
                    + "\(DebugLog.count(refined.count, "directory", "directories")) "
                    + "in \(debug?.elapsed(since: started) ?? "")"
                    + (refined.isEmpty
                        ? "; nothing under these roots can match"
                        : ": " + DebugLog.list(refined.map(\.typed))))
        } else if let debug, !plan.anchors.isEmpty {
            let names = plan.anchors.map(\.name)
            if plan.anchors.allSatisfy({ anchor in
                roots.contains { anchor.isSatisfied(byRootTyped: $0.typed) }
            }) {
                debug.log(
                    "path anchor(s) \(DebugLog.list(names)) already satisfied by a root; "
                        + "not used")
            } else if !mode.walks, !plan.isMatchAll {
                debug.log(
                    "path anchor(s) \(DebugLog.list(names)) not used: the query already "
                        + "narrows, and no walk follows")
            }
        }
        indexRoots = queryRoots

        // Phase 2: the index.
        if !queryRoots.isEmpty {
            usedIndex = true
            let started = Date()
            let before = delivered
            debug?.log(
                "spotlight query: \(plan.queryString ?? "none (the expression cannot match indexed files; only the roots are seeded)")"
            )
            debug?.log(
                "spotlight scope: \(DebugLog.list(queryRoots.map(\.absolute)))")
            progress?.setPhase("querying index", fraction: nil)
            let source = MDQuerySource(queryString: plan.queryString, roots: queryRoots, skip: skip)
            if let progress {
                _ = try progress.withRunLoopTimer { try source.forEachCandidate(deliver) }
            } else {
                _ = try source.forEachCandidate(deliver)
            }
            indexResultCount = source.indexResultCount
            if let debug {
                var summary =
                    "spotlight results: \(DebugLog.count(indexResultCount, "item")) returned, "
                    + "\(DebugLog.count(delivered - before, "candidate")) delivered to the "
                    + "post-filter in \(debug.elapsed(since: started))"
                if !skip.isEmpty {
                    summary += " (paths the exhaustive walk already delivered are skipped)"
                }
                if indexResultCount == 0 {
                    summary += "; the index has nothing matching the query under this scope"
                }
                debug.log(summary)
            }
            if stopped { return delivered }
        } else if plan.queryString != nil {
            debug?.log("spotlight query skipped: no root for the index to search")
        }

        // Phase 3: the gap walk (and exhaustive walks of uncovered roots).
        if mode.walks {
            let walkRoots =
                queryRoots.map { WalkRoot(scope: $0, exhaustive: false) }
                + unindexedRoots.map { WalkRoot(scope: $0, exhaustive: true) }
            guard !walkRoots.isEmpty else { return delivered }
            var options = walkOptions()
            options.skip = skip
            if !queryRoots.isEmpty, !queryRoots.contains(where: \.isHidden) {
                // The index's own folder list is the authoritative map of what it
                // covers below these roots; directories missing from it are walked
                // exhaustively. (Content type is not queryable in the reduced tier.)
                progress?.setPhase("listing indexed folders", fraction: nil)
                let started = Date()
                let folders = MDQuerySource.synchronousCandidates(
                    query: "kMDItemContentTypeTree == \"public.folder\"", roots: queryRoots)
                options.indexedDirectories = Set(folders.map(\.candidate.path))
                debug?.log(
                    "indexed folder list: \(DebugLog.count(folders.count, "directory", "directories")) "
                        + "under the scope in \(debug?.elapsed(since: started) ?? ""); "
                        + "directories missing from it are walked exhaustively")
            } else if !queryRoots.isEmpty {
                debug?.log(
                    "indexed folder list skipped: a root is a hidden directory "
                        + "(content type is not queryable there)")
            }
            let walker = makeWalker(roots: walkRoots, options: options)
            let started = Date()
            debug?.log(
                "gap walk: \(DebugLog.count(queryRoots.count, "indexed root")) "
                    + "(only unindexed entries are yielded) and "
                    + "\(DebugLog.count(unindexedRoots.count, "unindexed root")) (yielded in full)")
            progress?.setPhase("walking", fraction: 0)
            let outcome = try walker.run(deliver)
            debug?.log(
                "gap walk: scanned \(DebugLog.count(walker.scanned, "entry", "entries")), "
                    + "yielded \(DebugLog.count(walker.yielded, "candidate")), entered "
                    + "\(DebugLog.count(walker.gapSubtrees, "gap subtree")) in "
                    + "\(debug?.elapsed(since: started) ?? "")"
                    + (outcome == .stopped ? "; stopped early" : ""))
        }
        return delivered
    }

    private func walkOptions() -> WalkOptions {
        var options = WalkOptions()
        options.symlinks = command.options.symlinks
        options.maxDepth = command.globals.maxDepth
        options.sameDevice = command.globals.sameDevice
        options.depthFirst = command.globals.depthFirst
        return options
    }

    private func makeWalker(roots: [WalkRoot], options: WalkOptions) -> Walker {
        let walker = Walker(roots: roots, options: options, progress: progress)
        walker.shouldDescend = shouldDescend
        walker.diagnostic = { [sink] message in sink.diagnostic(message) }
        if let debug {
            walker.onGapSubtree = { [weak self] path, reason in
                guard let self else { return }
                self.gapSubtreesLogged += 1
                if self.gapSubtreesLogged <= 25 {
                    debug.log("gap subtree: \(path) (\(reason))")
                } else if self.gapSubtreesLogged == 26 {
                    debug.log("further gap subtrees are not listed")
                }
            }
        }
        return walker
    }

    /// The anchor directories under `roots` according to the index, as roots of their
    /// own (nested ones collapsed into their ancestors). An empty result means the
    /// index knows no such directory, so nothing under these roots can match.
    static func refine(_ roots: [RootScope], by anchor: PathAnchor) -> (
        query: String, roots: [RootScope]
    ) {
        let escaped = anchor.name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var query = "kMDItemFSName == \"\(escaped)\"\(anchor.caseInsensitive ? "c" : "")"
        if !roots.contains(where: \.isHidden) {
            // Content type is not served in the reduced (hidden-root) tier.
            query = "(\(query) && kMDItemContentTypeTree == \"public.folder\")"
        }
        let matches = MDQuerySource.synchronousCandidates(query: query, roots: roots).filter {
            let last = $0.candidate.lastComponent
            return anchor.caseInsensitive
                ? last.lowercased() == anchor.name.lowercased() : last == anchor.name
        }
        var refined: [RootScope] = []
        for (raw, candidate) in matches.sorted(by: {
            $0.candidate.path.count < $1.candidate.path.count
        }) {
            if refined.contains(where: { candidate.path.hasPrefix($0.typed + "/") }) { continue }
            var canonical = raw
            if let resolved = realpath(raw, nil) {
                canonical = String(cString: resolved)
                free(resolved)
            }
            refined.append(
                RootScope(
                    typed: candidate.path, absolute: raw, canonical: canonical,
                    device: candidate.rootDevice, depthOffset: candidate.depth))
        }
        return (query, refined)
    }
}
