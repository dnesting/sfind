import Darwin
import Foundation

/// The complete CLI pipeline: parse → plan (with warnings) → MDQuery → post-filter →
/// actions. This is what `sfind`'s main calls; tests drive it with a CollectingSink.
public enum SFindCLI {
    static let usage =
        "usage: sfind [-H | -L | -P] [-EXdsx] [-f path] [--walk[=MODE]] [--progress] "
        + "[--debug] path ... [--expr string] [expression]"

    public static func run(arguments: [String], sink: OutputSink) -> Int32 {
        switch arguments.first {
        case "--help", "-?":
            sink.write(helpText)
            sink.flush()
            return 0
        case "--version":
            sink.write("sfind \(SFind.version)\n")
            sink.flush()
            return 0
        default:
            break
        }

        let command: ParsedCommand
        do {
            command = try CommandParser().parse(arguments)
        } catch {
            sink.diagnostic("\(error)")
            sink.diagnostic(usage)
            sink.flush()
            return 1
        }

        let environment = PlannerEnvironment.live()
        var sawError = false

        // Validate roots (find diagnoses missing operands and continues with the rest).
        var roots: [RootScope] = []
        for path in command.paths {
            if FileInfo.lstat(path) == nil {
                sink.diagnostic("\(path): No such file or directory")
                sawError = true
                continue
            }
            roots.append(
                RootScope(typed: path, followSymlinks: command.options.symlinks != .never))
        }

        let plan: QueryPlan
        do {
            let planner = Planner(
                environment: environment, reducedTier: roots.contains(where: \.isHidden))
            plan = try planner.plan(command)
        } catch {
            sink.diagnostic("\(error)")
            sink.flush()
            return 1
        }
        let walk = command.options.walk
        let debug = command.options.debug ? DebugLog(sink: sink) : nil
        if let debug {
            for root in roots {
                var line = "root '\(root.typed)': \(root.absolute)"
                if root.canonical != root.absolute { line += " (canonical \(root.canonical))" }
                if let device = root.device { line += ", device \(device)" }
                if root.isHidden {
                    line += "; a hidden directory (reduced index tier: names, owners, dates only)"
                } else if root.isInsideHiddenDirectory {
                    line += "; inside a hidden directory (index scoping unreliable)"
                }
                if let marker = root.exclusionMarkerDirectory {
                    line += "; excluded from the index by \(display(marker, like: root))"
                }
                debug.log(line)
            }
            debug.log(
                "planned spotlight query: "
                    + (plan.queryString ?? "none (the expression cannot match indexed files)"))
            if plan.isMatchAll {
                debug.log("the query narrows nothing: the index returns the whole scope")
            }
            if !plan.postFilterOnly.isEmpty {
                debug.log("post-filter only: \(plan.postFilterOnly.joined(separator: ", "))")
            }
            if !plan.anchors.isEmpty {
                debug.log("path anchors: \(DebugLog.list(plan.anchors.map(\.name)))")
            }
            debug.log("walk mode: \(walk.rawValue)")
        }
        // Predicate-level warnings: only for expression terms that provably require
        // files Spotlight cannot return (-type l, -lname, dot-name patterns). A walk
        // covers exactly those files, so they are moot then.
        if !walk.walks {
            for warning in plan.warnings {
                sink.diagnostic("warning: \(warning.message)")
            }
        }
        if !walk.usesIndex,
            !plan.contentNeedingMembership.isEmpty || !plan.contentSatisfiedByIndex.isEmpty
        {
            sink.diagnostic(
                "warning: -content is answered by the Spotlight index, which --walk=only "
                    + "never consults; it matches nothing")
        }

        if command.options.translateOnly {
            return emitMDFind(plan: plan, roots: roots, sink: sink)
        }

        var progress: Progress?
        if command.options.progress {
            let reporter = Progress.standardError()
            progress = reporter
            (sink as? FileHandleSink)?.beforeWrite = { reporter.clearLine() }
        } else if debug != nil {
            // Counters only, for the final debug summary.
            progress = Progress.silent()
        }
        defer {
            if command.options.progress { progress?.finish() }
        }

        // -content terms the main query cannot vouch for (under a negation or
        // disjunction, or in the reduced tier) get their own membership sets. So does
        // every term when walking: a small scope may never reach the index query, and
        // walked candidates carry no "came from the index" evidence.
        var content = Evaluator.ContentResolution(
            satisfiedByIndex: walk.walks ? [] : plan.contentSatisfiedByIndex)
        if walk.usesIndex {
            let terms =
                walk.walks
                ? plan.contentNeedingMembership + plan.contentSatisfiedByIndex.sorted()
                : plan.contentNeedingMembership
            for words in terms {
                let query = Planner.contentQuery(words)
                let paths = MDQuerySource.synchronousCandidates(query: query, roots: roots)
                content.membership[words] = Set(paths.map(\.candidate.path))
                debug?.log(
                    "content term '\(words)': \(query) → "
                        + "\(DebugLog.count(paths.count, "indexed file"))")
            }
            for words in plan.contentSatisfiedByIndex where !walk.walks {
                debug?.log(
                    "content term '\(words)': a conjunct of the query; true for every "
                        + "index result")
            }
        }

        let source = HybridSource(
            command: command, plan: plan, roots: roots, sink: sink, progress: progress,
            debug: debug)
        let runner = Runner(
            command: command, environment: environment, sink: sink, content: content,
            progress: progress)
        let status = runner.run(source: source)
        if let debug, let counters = progress?.counters {
            debug.log(
                "post-filter: \(DebugLog.count(counters.query + counters.walk, "candidate")) "
                    + "(\(Progress.group(counters.query)) from the index, "
                    + "\(Progress.group(counters.walk)) from the walk or seeded as roots); "
                    + "\(Progress.group(counters.filtered)) rejected, "
                    + "\(Progress.group(counters.matched)) matched; "
                    + "exit status \(sawError ? 1 : status); \(debug.elapsed()) total")
        }

        // Scope diagnostics are deferred: when the index returned nothing, ask it the
        // authoritative question per root — "is ANYTHING under this root indexed?" —
        // and explain the emptiness. This stays accurate even when heuristics
        // (markers, hidden dirs) would guess wrong in either direction. A walk
        // already handles uncovered roots itself.
        if walk == .off, source.indexResultCount == 0, plan.queryString != nil {
            for root in roots where !MDQuerySource.indexHasAnyEntry(under: root) {
                var message =
                    "warning: \(root.typed): this search root is not in the Spotlight "
                    + "index (nothing under it is indexed)"
                if let marker = root.exclusionMarkerDirectory {
                    message +=
                        "; likely cause: \(display(marker, like: root)) carries a "
                        + ".metadata_never_index marker or .noindex name"
                } else if root.isInsideHiddenDirectory {
                    message += "; likely cause: the path is inside a hidden directory"
                }
                sink.diagnostic(message)
                sink.flush()
            }
        }
        return sawError ? 1 : status
    }

    /// --mdfind: print the equivalent mdfind invocation instead of running it.
    private static func emitMDFind(plan: QueryPlan, roots: [RootScope], sink: OutputSink)
        -> Int32
    {
        guard let query = plan.queryString else {
            sink.diagnostic(
                "--mdfind: the expression can only match files Spotlight does not index; "
                    + "no query would return them")
            sink.flush()
            return 1
        }
        for name in plan.postFilterOnly {
            sink.diagnostic(
                "note: `\(name)` is not expressible in a Spotlight query; "
                    + "mdfind results will be a superset")
        }
        var pieces = ["mdfind"]
        for root in roots {
            pieces.append("-onlyin")
            pieces.append(shellQuote(root.absolute))
        }
        pieces.append("-literal")
        pieces.append(shellQuote(query))
        sink.write(pieces.joined(separator: " ") + "\n")
        sink.flush()
        return 0
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Renders a warning path relative to the working directory when the user typed a
    /// relative root (".." segments as needed); absolute roots keep absolute paths.
    public static func display(_ path: String, like root: RootScope) -> String {
        guard !root.typed.hasPrefix("/"), !root.typed.hasPrefix("~") else { return path }
        var cwd = FileManager.default.currentDirectoryPath
        if let resolved = realpath(cwd, nil) {
            cwd = String(cString: resolved)
            free(resolved)
        }
        let target = path.split(separator: "/", omittingEmptySubsequences: true)
        let base = cwd.split(separator: "/", omittingEmptySubsequences: true)
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] {
            common += 1
        }
        let ups = base.count - common
        let downs = target[common...]
        var parts = Array(repeating: "..", count: ups) + downs.map(String.init)
        if parts.isEmpty { parts = ["."] }
        return parts.joined(separator: "/")
    }

    static let helpText = """
        \(usage)

        sfind evaluates find(1) expressions against the Spotlight index instead of
        walking the filesystem. BSD find semantics are ground truth; conflict-free GNU
        extensions are included. By default results are limited to what Spotlight
        indexes — see the CAVEATS section of sfind(1) or SPEC.md for the gaps
        (dotfiles, symlinks, excluded trees); --walk fills them in.

        Options (before paths):
          -H | -L | -P   symlink handling for roots / everywhere / never (default -P)
          -E             extended regular expressions for -regex/-iregex
          -X             skip filenames unsafe for xargs, with a diagnostic
          -d             depth-first: -prune is inert, actions still run per file
          -f path        add path to the search roots
          -s             sort results (find-compatible per-directory lexicographic order)
          -x             do not cross device boundaries

        sfind-specific:
          --expr STRING  supply expression tokens as one string; parentheses and !
                         need no shell escaping:
                             sfind ~/Docs --expr '(-name "*.md" -o -name "*.txt") -mtime -7'
          --mdfind       print the equivalent mdfind invocation instead of running it
          --walk[=MODE]  supplement the index with a filesystem walk. gaps (the
                         default for bare --walk) walks only what Spotlight does not
                         index: dot entries, symlinks and special files, .noindex /
                         .metadata_never_index / package subtrees, and roots the index
                         has nothing for; small scopes are walked outright. only never
                         consults the index (a plain find). off is the default.
          --progress     show a progress line on stderr: an estimate of the work left
                         plus candidates from the query, from the walk, filtered out,
                         and matched
          --debug        explain on stderr where the search looks and what it finds:
                         each root's index status, the Spotlight query and scope and
                         how many items it returned, the walk phases with what they
                         scanned and yielded (and which subtrees were treated as
                         unindexed), and the post-filter totals — for tracing an
                         unexpected or empty result to its cause
          --help, -?     this help
          --version      version

        Expression: the find(1) primaries and operators, including -name/-iname,
        -path/-ipath, -regex/-iregex, -type, -size, -mtime/-newer/... (all -newerXY
        forms), -user/-group, -perm, -empty, -links, -inum, -samefile, -flags, -acl,
        -xattr(name), -maxdepth/-mindepth, -prune, and the actions -print, -print0,
        -ls, -exec/-execdir/-ok/-okdir, -delete, -quit. GNU extensions: -printf,
        -regextype, -readable/-writable/-executable, -daystart, -perm /mode.
        sfind extension: -content WORDS matches files whose Spotlight-indexed text
        contains every word (case-insensitive; * wildcards; whole words otherwise).

        Exit status: 0 unless an error occurred (match count is irrelevant, like find).

        """
}
