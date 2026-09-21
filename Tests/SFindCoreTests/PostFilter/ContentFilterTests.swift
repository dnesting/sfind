import Foundation
import SFindCore
import Testing

/// -content evaluation over an ArraySource: the term's truth comes from the
/// ContentResolution handed to the Runner, never from the file itself.
@Suite struct ContentFilterTests {
    /// a.txt and b.txt are marked as index results; c.txt and the root are not.
    func fixture() throws -> (tree: TempTree, candidates: [Candidate]) {
        let tree = try TempTree()
        try tree.file("a.txt")
        try tree.file("b.txt")
        try tree.file("c.txt")
        let candidates = tree.candidates().map { candidate in
            var marked = candidate
            marked.fromIndex =
                candidate.lastComponent == "a.txt" || candidate.lastComponent == "b.txt"
            return marked
        }
        return (tree, candidates)
    }

    func run(
        _ tokens: [String], tree: TempTree, candidates: [Candidate],
        content: Evaluator.ContentResolution, progress: SFindCore.Progress? = nil
    ) throws -> (relative: [String], status: Int32, sink: CollectingSink) {
        let command = try CommandParser().parse([tree.root] + tokens)
        let sink = CollectingSink()
        let runner = Runner(
            command: command, environment: .live(), sink: sink, content: content,
            progress: progress)
        let status = runner.run(source: ArraySource(candidates))
        let relative = sink.lines.map { line in
            line == tree.root ? "." : String(line.dropFirst(tree.root.count + 1))
        }.sorted()
        return (relative, status, sink)
    }

    @Test func termSatisfiedByIndexIsTrueForIndexCandidates() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra"], tree: tree, candidates: candidates,
            content: .init(satisfiedByIndex: ["zebra"]))
        #expect(result.relative == ["a.txt", "b.txt"])
        #expect(result.status == 0)
    }

    @Test func termWithMembershipIsTrueForListedPaths() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra"], tree: tree, candidates: candidates,
            content: .init(membership: ["zebra": [tree.root + "/c.txt"]]))
        #expect(result.relative == ["c.txt"])
    }

    @Test func membershipIgnoresIndexProvenance() throws {
        let (tree, candidates) = try fixture()
        // Membership answers by path even for an index candidate; provenance is not
        // consulted for a term that is not in satisfiedByIndex.
        let result = try run(
            ["-content", "zebra"], tree: tree, candidates: candidates,
            content: .init(membership: ["zebra": [tree.root + "/a.txt"]]))
        #expect(result.relative == ["a.txt"])
    }

    @Test func satisfiedByIndexTakesPrecedenceOverMembership() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra"], tree: tree, candidates: candidates,
            content: .init(
                satisfiedByIndex: ["zebra"], membership: ["zebra": [tree.root + "/c.txt"]]))
        #expect(result.relative == ["a.txt", "b.txt"])
    }

    @Test func unresolvedTermMatchesNothing() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra"], tree: tree, candidates: candidates, content: .init())
        #expect(result.relative.isEmpty)
        #expect(result.status == 0)
        #expect(result.sink.diagnostics.isEmpty)
    }

    @Test func termsAreMatchedByExactWords() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra fish"], tree: tree, candidates: candidates,
            content: .init(satisfiedByIndex: ["zebra"]))
        #expect(result.relative.isEmpty)
    }

    @Test func negatedAndDisjoinedContent() throws {
        let (tree, candidates) = try fixture()
        let membership: Evaluator.ContentResolution = .init(
            membership: ["zebra": [tree.root + "/c.txt"]])
        let negated = try run(
            ["-type", "f", "!", "-content", "zebra"], tree: tree, candidates: candidates,
            content: membership)
        #expect(negated.relative == ["a.txt", "b.txt"])
        let disjoined = try run(
            ["(", "-content", "zebra", "-o", "-name", "a.txt", ")"], tree: tree,
            candidates: candidates, content: membership)
        #expect(disjoined.relative == ["a.txt", "c.txt"])
    }

    @Test func mixedResolutionsInOneExpression() throws {
        let (tree, candidates) = try fixture()
        let result = try run(
            ["-content", "zebra", "-content", "fish"], tree: tree, candidates: candidates,
            content: .init(
                satisfiedByIndex: ["zebra"], membership: ["fish": [tree.root + "/b.txt"]]))
        #expect(result.relative == ["b.txt"])
    }

    @Test func wouldPruneIsSideEffectFree() throws {
        let tree = try TempTree()
        try tree.dir("d")
        try tree.file("d/inner.txt")
        try tree.file("x")
        let command = try CommandParser().parse([
            tree.root, "-name", "d", "-prune", "-o", "-print",
        ])
        let sink = CollectingSink()
        let evaluator = try Evaluator(command: command, environment: .live(), sink: sink)
        #expect(evaluator.wouldPrune(Candidate(path: tree.root + "/d", depth: 1)))
        #expect(!evaluator.wouldPrune(Candidate(path: tree.root + "/x", depth: 1)))
        #expect(!evaluator.wouldPrune(Candidate(path: tree.root + "/d/inner.txt", depth: 2)))
        #expect(!evaluator.wouldPrune(Candidate(path: tree.root, depth: 0)))
        #expect(!evaluator.wouldPrune(Candidate(path: tree.root + "/missing", depth: 1)))
        #expect(sink.text.isEmpty)
        #expect(sink.diagnostics.isEmpty)
        #expect(!evaluator.sawError)
    }

    @Test func wouldPruneHonorsDepthGlobals() throws {
        let tree = try TempTree()
        try tree.dir("d")
        let command = try CommandParser().parse([
            tree.root, "-mindepth", "2", "-name", "d", "-prune", "-o", "-print",
        ])
        let evaluator = try Evaluator(
            command: command, environment: .live(), sink: CollectingSink())
        #expect(!evaluator.wouldPrune(Candidate(path: tree.root + "/d", depth: 1)))
    }

    @Test func runnerProgressCountersSplitByProvenance() throws {
        let (tree, candidates) = try fixture()
        var written: [String] = []
        let progress = SFindCore.Progress(
            write: { written.append(String(decoding: $0, as: UTF8.self)) }, terminal: false,
            clock: { 0 })
        let result = try run(
            ["-name", "*.txt"], tree: tree, candidates: candidates, content: .init(),
            progress: progress)
        #expect(result.relative == ["a.txt", "b.txt", "c.txt"])
        let counters = progress.counters
        #expect(counters.matched + counters.filtered == candidates.count)
        #expect(counters.matched == 3)
        #expect(counters.filtered == 1)
        #expect(counters.query == candidates.filter(\.fromIndex).count)
        #expect(counters.walk == candidates.filter { !$0.fromIndex }.count)
        #expect(counters.query == 2)
        #expect(counters.walk == 2)
        #expect(counters.scanned == 0)
        #expect(!written.isEmpty)
    }

    @Test func runnerProgressCountsDepthSkippedCandidatesAsFiltered() throws {
        let (tree, candidates) = try fixture()
        let progress = SFindCore.Progress(write: { _ in }, terminal: false, clock: { 0 })
        let result = try run(
            ["-maxdepth", "0"], tree: tree, candidates: candidates, content: .init(),
            progress: progress)
        #expect(result.relative == ["."])
        #expect(progress.counters.matched == 1)
        #expect(progress.counters.filtered == candidates.count - 1)
    }
}
