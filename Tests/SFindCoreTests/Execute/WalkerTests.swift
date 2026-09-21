import Darwin
import Foundation
import SFindCore
import Testing

@Suite struct WalkerTests {
    func root(_ path: String, exhaustive: Bool = true) -> WalkRoot {
        WalkRoot(scope: RootScope(typed: path, followSymlinks: false), exhaustive: exhaustive)
    }

    /// Runs a walker over `roots`, returning the yielded paths in order and the outcome.
    func walk(
        _ roots: [WalkRoot], options: WalkOptions = WalkOptions(),
        configure: (Walker) -> Void = { _ in }
    ) throws -> (paths: [String], outcome: Walker.Outcome, walker: Walker) {
        let walker = Walker(roots: roots, options: options)
        configure(walker)
        var paths: [String] = []
        let outcome = try walker.run { candidate in
            paths.append(candidate.path)
            return true
        }
        return (paths, outcome, walker)
    }

    /// /usr/bin/find's output lines, unsorted (traversal order).
    func findOrder(_ arguments: [String]) throws -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// A tree with a couple of nested directories so pre- and post-order differ.
    func nestedTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.dir("a/b")
        try tree.dir("c")
        try tree.file("a/f1")
        try tree.file("a/b/f2")
        try tree.file("c/f3")
        try tree.file("top")
        return tree
    }

    @Test func exhaustiveRootYieldsEverythingInFindOrder() throws {
        let tree = try nestedTree()
        let (paths, outcome, _) = try walk([root(tree.root)])
        #expect(outcome == .completed)
        #expect(Set(paths) == Set(tree.candidates().map(\.path)))
        #expect(paths.count == tree.candidates().count)
        #expect(paths == (try findOrder([tree.root])))
    }

    @Test func candidatesCarryDepthAndRootDevice() throws {
        let tree = try nestedTree()
        let scope = RootScope(typed: tree.root, followSymlinks: false)
        let walker = Walker(
            roots: [WalkRoot(scope: scope, exhaustive: true)], options: WalkOptions())
        var depths: [String: Int] = [:]
        var devices = Set<Int32?>()
        try walker.run { candidate in
            depths[candidate.path] = candidate.depth
            devices.insert(candidate.rootDevice)
            return true
        }
        #expect(depths[tree.root] == 0)
        #expect(depths[tree.root + "/a"] == 1)
        #expect(depths[tree.root + "/a/b"] == 2)
        #expect(depths[tree.root + "/a/b/f2"] == 3)
        #expect(devices == [scope.device])
        #expect(walker.yielded == depths.count)
    }

    @Test func depthFirstMatchesFindD() throws {
        let tree = try nestedTree()
        var options = WalkOptions()
        options.depthFirst = true
        let (paths, outcome, _) = try walk([root(tree.root)], options: options)
        #expect(outcome == .completed)
        #expect(paths == (try findOrder(["-d", tree.root])))
        #expect(paths.last == tree.root)
        let a = try #require(paths.firstIndex(of: tree.root + "/a"))
        let f2 = try #require(paths.firstIndex(of: tree.root + "/a/b/f2"))
        #expect(f2 < a)
    }

    @Test func gapRootYieldsOnlyWhatSpotlightSkips() throws {
        let tree = try TempTree()
        try tree.file("regular.txt")
        try tree.dir("dir")
        try tree.file("dir/inner.txt")
        try tree.file(".dotfile")
        try tree.dir(".dotdir")
        try tree.file(".dotdir/x.txt")
        try tree.symlink("link", to: "regular.txt")
        try tree.dir("Cache.noindex")
        try tree.file("Cache.noindex/c.txt")
        try tree.dir("marked")
        try tree.file("marked/.metadata_never_index")
        try tree.file("marked/m.txt")
        try tree.dir("Bundle.app/Contents")
        try tree.file("Bundle.app/Contents/Info.plist")

        var expected: Set<String> = [
            ".dotfile", ".dotdir", ".dotdir/x.txt", "link", "Cache.noindex/c.txt",
            "marked/.metadata_never_index", "marked/m.txt",
        ]
        // Package detection comes from LaunchServices; only assert on the bundle's
        // contents when this machine treats a bare .app directory as a package.
        let isPackage =
            (try? URL(fileURLWithPath: tree.root + "/Bundle.app")
                .resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isPackage {
            expected.formUnion(["Bundle.app/Contents", "Bundle.app/Contents/Info.plist"])
        }

        let (paths, outcome, _) = try walk([root(tree.root, exhaustive: false)])
        #expect(outcome == .completed)
        let relative = Set(paths.map { String($0.dropFirst(tree.root.count + 1)) })
        #expect(relative == expected)
        #expect(!paths.contains(tree.root))
        for absent in [
            "regular.txt", "dir", "dir/inner.txt", "Cache.noindex", "marked", "Bundle.app",
        ] {
            #expect(!relative.contains(absent), "\(absent)")
        }
    }

    @Test func skipSuppressesPathsButStillDescends() throws {
        let tree = try nestedTree()
        var options = WalkOptions()
        options.skip = [tree.root + "/a", tree.root + "/top"]
        let (paths, _, _) = try walk([root(tree.root)], options: options)
        #expect(!paths.contains(tree.root + "/a"))
        #expect(!paths.contains(tree.root + "/top"))
        #expect(paths.contains(tree.root + "/a/f1"))
        #expect(paths.contains(tree.root + "/a/b/f2"))
        #expect(paths.count == tree.candidates().count - 2)
    }

    @Test func limitStopsAfterThatManyCandidates() throws {
        let tree = try nestedTree()
        var options = WalkOptions()
        options.limit = 3
        let (paths, outcome, walker) = try walk([root(tree.root)], options: options)
        #expect(outcome == .limitReached)
        #expect(paths.count == 3)
        #expect(walker.yielded == 3)
        #expect(walker.emitted == Set(paths))
    }

    @Test func timeLimitUsesInjectedClock() throws {
        let tree = try nestedTree()
        var options = WalkOptions()
        options.timeLimit = 1
        var ticks = 0
        // The first reading establishes the deadline; every later one is past it.
        let walker = Walker(
            roots: [root(tree.root)], options: options,
            clock: {
                ticks += 1
                return ticks == 1 ? 0 : 1000
            })
        var paths: [String] = []
        let outcome = try walker.run { candidate in
            paths.append(candidate.path)
            return true
        }
        #expect(outcome == .limitReached)
        #expect(paths.count >= 1)
        #expect(paths.count < tree.candidates().count)
        #expect(walker.yielded == paths.count)
        #expect(walker.emitted == Set(paths))
    }

    @Test func emittedIsTrackedOnlyUnderLimits() throws {
        let tree = try nestedTree()
        let (paths, _, walker) = try walk([root(tree.root)])
        #expect(walker.emitted.isEmpty)
        #expect(walker.yielded == paths.count)
    }

    @Test func maxDepthNeverReadsDeeperDirectories() throws {
        let tree = try TempTree()
        try tree.dir("d1/d2")
        try tree.file("d1/d2/f")
        try tree.file("d1/f1")
        try tree.file("f0")
        // A depth-1 directory is yielded but not opened under -maxdepth 1, so making
        // it unreadable produces no error.
        let d1 = tree.root + "/d1"
        chmod(d1, 0)
        defer { chmod(tree.root + "/d1", 0o755) }

        var options = WalkOptions()
        options.maxDepth = 1
        let (paths, outcome, walker) = try walk([root(tree.root)], options: options)
        #expect(outcome == .completed)
        #expect(Set(paths) == [tree.root, d1, tree.root + "/f0"])
        #expect(!walker.sawError)

        options.maxDepth = 0
        let (onlyRoot, _, _) = try walk([root(tree.root)], options: options)
        #expect(onlyRoot == [tree.root])
    }

    @Test func bodyReturningFalseStops() throws {
        let tree = try nestedTree()
        let walker = Walker(roots: [root(tree.root)], options: WalkOptions())
        var seen = 0
        let outcome = try walker.run { _ in
            seen += 1
            return seen < 2
        }
        #expect(outcome == .stopped)
        #expect(seen == 2)
        #expect(walker.yielded == 2)
    }

    @Test func shouldDescendSuppressesSubtree() throws {
        let tree = try nestedTree()
        let a = tree.root + "/a"
        let (paths, outcome, _) = try walk([root(tree.root)]) { walker in
            walker.shouldDescend = { $0.path != a }
        }
        #expect(outcome == .completed)
        #expect(paths.contains(a))
        #expect(!paths.contains(a + "/f1"))
        #expect(!paths.contains(a + "/b"))
        #expect(paths.contains(tree.root + "/c/f3"))

        // Refusing the root itself yields only the root.
        let (rootOnly, _, _) = try walk([root(tree.root)]) { walker in
            walker.shouldDescend = { _ in false }
        }
        #expect(rootOnly == [tree.root])
    }

    @Test func shouldDescendIsIgnoredDepthFirst() throws {
        let tree = try nestedTree()
        var options = WalkOptions()
        options.depthFirst = true
        let (paths, _, _) = try walk([root(tree.root)], options: options) { walker in
            walker.shouldDescend = { _ in false }
        }
        #expect(Set(paths) == Set(tree.candidates().map(\.path)))
    }

    @Test func followingSymlinksDescendsAndDetectsCycles() throws {
        let tree = try TempTree()
        try tree.dir("real")
        try tree.file("real/inner.txt")
        try tree.symlink("linkdir", to: "real")
        try tree.symlink("real/loop", to: "..")

        var options = WalkOptions()
        options.symlinks = .always
        var diagnostics: [String] = []
        let (paths, outcome, walker) = try walk([root(tree.root)], options: options) { walker in
            walker.diagnostic = { diagnostics.append($0) }
        }
        #expect(outcome == .completed)
        #expect(paths.contains(tree.root + "/linkdir/inner.txt"))
        #expect(paths.contains(tree.root + "/linkdir/loop"))
        #expect(paths.contains(tree.root + "/real/loop"))
        #expect(!paths.contains(tree.root + "/real/loop/real"))
        #expect(!paths.contains(tree.root + "/linkdir/loop/real"))
        #expect(walker.sawError)
        #expect(
            diagnostics.contains { $0.hasPrefix(tree.root + "/real/loop") && $0.contains("loop") })
        #expect(
            diagnostics.contains {
                $0.hasPrefix(tree.root + "/linkdir/loop") && $0.contains("loop")
            })
    }

    @Test func notFollowingSymlinksTreatsDirectoryLinksAsLeaves() throws {
        let tree = try TempTree()
        try tree.dir("real")
        try tree.file("real/inner.txt")
        try tree.symlink("linkdir", to: "real")
        let (paths, _, walker) = try walk([root(tree.root)])
        #expect(paths.contains(tree.root + "/linkdir"))
        #expect(!paths.contains(tree.root + "/linkdir/inner.txt"))
        #expect(!walker.sawError)
    }

    @Test(.enabled(if: geteuid() != 0, "root can read every directory"))
    func unreadableDirectoryIsReportedAndSkipped() throws {
        let tree = try TempTree()
        try tree.dir("locked")
        try tree.file("locked/x.txt")
        try tree.file("other.txt")
        try tree.dir("open")
        try tree.file("open/y.txt")
        let locked = tree.root + "/locked"
        chmod(locked, 0)
        defer { chmod(tree.root + "/locked", 0o755) }

        var diagnostics: [String] = []
        let (paths, outcome, walker) = try walk([root(tree.root)]) { walker in
            walker.diagnostic = { diagnostics.append($0) }
        }
        #expect(outcome == .completed)
        #expect(walker.sawError)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.hasPrefix(locked + ": ") == true)
        #expect(diagnostics.first?.contains("Permission denied") == true)
        #expect(paths.contains(locked))
        #expect(!paths.contains(locked + "/x.txt"))
        #expect(paths.contains(tree.root + "/other.txt"))
        #expect(paths.contains(tree.root + "/open/y.txt"))
    }

    @Test(.enabled(if: geteuid() != 0, "root can read every directory"))
    func unreadableRootIsReported() throws {
        let tree = try TempTree()
        try tree.dir("locked")
        let locked = tree.root + "/locked"
        chmod(locked, 0)
        defer { chmod(tree.root + "/locked", 0o755) }
        var diagnostics: [String] = []
        let (paths, outcome, walker) = try walk([root(locked)]) { walker in
            walker.diagnostic = { diagnostics.append($0) }
        }
        #expect(outcome == .completed)
        #expect(paths == [locked])
        #expect(walker.sawError)
        #expect(diagnostics.first?.contains("Permission denied") == true)
    }

    @Test func multipleRootsAreWalkedInOrder() throws {
        let first = try nestedTree()
        let second = try TempTree()
        try second.file("only.txt")
        let (paths, outcome, _) = try walk([root(first.root), root(second.root)])
        #expect(outcome == .completed)
        #expect(
            Set(paths) == Set(first.candidates().map(\.path)).union(second.candidates().map(\.path))
        )
        let firstCount = first.candidates().count
        #expect(paths.prefix(firstCount).allSatisfy { $0.hasPrefix(first.root) })
        #expect(paths.dropFirst(firstCount).allSatisfy { $0.hasPrefix(second.root) })
        #expect(paths.first == first.root)
        #expect(paths[firstCount] == second.root)
    }

    @Test func limitSpansRoots() throws {
        let first = try TempTree()
        try first.file("x")
        let second = try TempTree()
        try second.file("y")
        var options = WalkOptions()
        options.limit = 3
        let (paths, outcome, _) = try walk([root(first.root), root(second.root)], options: options)
        #expect(outcome == .limitReached)
        #expect(paths == [first.root, first.root + "/x", second.root])
    }

    @Test func fileRootIsYieldedAlone() throws {
        let tree = try TempTree()
        let file = try tree.file("solo.txt")
        let (paths, outcome, walker) = try walk([root(file)])
        #expect(outcome == .completed)
        #expect(paths == [file])
        #expect(!walker.sawError)
        // A gap root that is a plain file is the index's responsibility.
        let (gap, _, _) = try walk([root(file, exhaustive: false)])
        #expect(gap.isEmpty)
    }

    @Test func gapRootsUnderDepthFirstDeferDirectories() throws {
        let tree = try TempTree()
        try tree.dir(".dotdir/sub")
        try tree.file(".dotdir/sub/x.txt")
        try tree.file("regular.txt")
        var options = WalkOptions()
        options.depthFirst = true
        let (paths, _, _) = try walk([root(tree.root, exhaustive: false)], options: options)
        #expect(
            paths == [
                tree.root + "/.dotdir/sub/x.txt", tree.root + "/.dotdir/sub",
                tree.root + "/.dotdir",
            ])
    }
    @Test func directoriesMissingFromIndexListStartGapSubtrees() throws {
        let tree = try TempTree()
        try tree.dir("indexed/sub")
        try tree.file("indexed/inner.txt")
        try tree.file("indexed/sub/deep.txt")
        try tree.dir("private")
        try tree.file("private/secret.txt")
        try tree.file("top.txt")
        var options = WalkOptions()
        options.indexedDirectories = [tree.root + "/indexed", tree.root + "/indexed/sub"]
        let (paths, outcome, _) = try walk([root(tree.root, exhaustive: false)], options: options)
        #expect(outcome == .completed)
        let relative = Set(paths.map { String($0.dropFirst(tree.root.count + 1)) })
        #expect(relative == ["private", "private/secret.txt"])

        // Without the list, only the name rules classify gaps.
        let (unlisted, _, _) = try walk([root(tree.root, exhaustive: false)])
        #expect(unlisted.isEmpty)
    }
}
