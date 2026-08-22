import Darwin
import Foundation

/// The complete CLI pipeline: parse → plan (with scope probing and warnings) →
/// MDQuery → post-filter → actions. This is what `sfind`'s main calls; tests drive it
/// with a CollectingSink.
public enum SFindCLI {
    public static func run(arguments: [String], sink: OutputSink) -> Int32 {
        let command: ParsedCommand
        do {
            command = try CommandParser().parse(arguments)
        } catch {
            sink.diagnostic("\(error)")
            sink.diagnostic(
                "usage: sfind [-H | -L | -P] [-EXdsx] [-f path] path ... [--expr string] [expression]"
            )
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

        // Scope-level completeness warnings.
        var reducedTier = false
        for root in roots {
            if let reason = root.exclusionReason {
                sink.diagnostic(
                    "warning: \(root.typed): \(reason); Spotlight cannot see this tree "
                        + "and results may be empty")
            } else if root.isInsideHiddenDirectory {
                sink.diagnostic(
                    "warning: \(root.typed): is inside a hidden directory; Spotlight "
                        + "scoping here is unreliable and results may be empty")
            }
            if root.isHidden {
                reducedTier = true
            }
        }

        let plan: QueryPlan
        do {
            let planner = Planner(environment: environment, reducedTier: reducedTier)
            plan = try planner.plan(command)
        } catch {
            sink.diagnostic("\(error)")
            sink.flush()
            return 1
        }
        for warning in plan.warnings {
            sink.diagnostic("warning: \(warning.message)")
        }

        let source = MDQuerySource(queryString: plan.queryString, roots: roots)
        let runner = Runner(command: command, environment: environment, sink: sink)
        let status = runner.run(source: source)
        return sawError ? 1 : status
    }
}
