import Darwin
import Foundation

/// The complete CLI pipeline: parse → plan (with warnings) → MDQuery → post-filter →
/// actions. This is what `sfind`'s main calls; tests drive it with a CollectingSink.
public enum SFindCLI {
    static let usage =
        "usage: sfind [-H | -L | -P] [-EXdsx] [-f path] path ... [--expr string] [expression]"

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
        // Predicate-level warnings: only for expression terms that provably require
        // files Spotlight cannot return (-type l, -lname, dot-name patterns).
        for warning in plan.warnings {
            sink.diagnostic("warning: \(warning.message)")
        }

        if command.options.translateOnly {
            return emitMDFind(plan: plan, roots: roots, sink: sink)
        }

        let source = MDQuerySource(queryString: plan.queryString, roots: roots)
        let runner = Runner(command: command, environment: environment, sink: sink)
        let status = runner.run(source: source)

        // Scope diagnostics are deferred: when the index returned nothing, ask it the
        // authoritative question per root — "is ANYTHING under this root indexed?" —
        // and explain the emptiness. This stays accurate even when heuristics
        // (markers, hidden dirs) would guess wrong in either direction.
        if source.indexResultCount == 0, plan.queryString != nil {
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
        extensions are included. Results are limited to what Spotlight indexes — see
        the CAVEATS section of sfind(1) or SPEC.md for the gaps (dotfiles, symlinks,
        excluded trees).

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
          --help, -?     this help
          --version      version

        Expression: the find(1) primaries and operators, including -name/-iname,
        -path/-ipath, -regex/-iregex, -type, -size, -mtime/-newer/... (all -newerXY
        forms), -user/-group, -perm, -empty, -links, -inum, -samefile, -flags, -acl,
        -xattr(name), -maxdepth/-mindepth, -prune, and the actions -print, -print0,
        -ls, -exec/-execdir/-ok/-okdir, -delete, -quit. GNU extensions: -printf,
        -regextype, -readable/-writable/-executable, -daystart, -perm /mode.

        Exit status: 0 unless an error occurred (match count is irrelevant, like find).

        """
}
