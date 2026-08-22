import Foundation

extension ParsedCommand {
    /// Lexical presence of a primary anywhere in the expression.
    public func containsPrimary(where predicate: (Primary) -> Bool) -> Bool {
        func walk(_ expression: Expression) -> Bool {
            switch expression {
            case .and(let children), .or(let children):
                return children.contains(where: walk)
            case .not(let child):
                return walk(child)
            case .primary(let primary):
                return predicate(primary)
            }
        }
        guard let expression else { return false }
        return walk(expression)
    }
}

/// Drives candidates from a source through the evaluator, honoring -s ordering,
/// -prune post-processing, -delete's children-first ordering, and -quit, and produces
/// find-compatible exit status (0 iff no errors; match count is irrelevant).
public final class Runner {
    let command: ParsedCommand
    let environment: PlannerEnvironment
    let sink: OutputSink
    let promptResponder: ((String) -> Bool)?

    public init(
        command: ParsedCommand, environment: PlannerEnvironment, sink: OutputSink,
        promptResponder: ((String) -> Bool)? = nil
    ) {
        self.command = command
        self.environment = environment
        self.sink = sink
        self.promptResponder = promptResponder
    }

    /// Sorts candidates in find -s order: lexicographic over path components.
    static func findSorted(_ candidates: [Candidate]) -> [Candidate] {
        candidates
            .map {
                (key: $0.path.split(separator: "/", omittingEmptySubsequences: true), value: $0)
            }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.value)
    }

    public func run(source: CandidateSource) -> Int32 {
        let evaluator: Evaluator
        let candidates: [Candidate]
        do {
            evaluator = try Evaluator(
                command: command, environment: environment, sink: sink,
                promptResponder: promptResponder)
            candidates = try source.candidates()
        } catch {
            sink.diagnostic("\(error)")
            sink.flush()
            return 1
        }

        let hasDelete = command.containsPrimary { primary in
            if case .delete = primary { return true }
            return false
        }
        // -delete implies depth-first, under which -prune is inert (find behavior).
        let pruneActive =
            !hasDelete && !command.globals.depthFirst
            && command.containsPrimary { primary in
                if case .prune = primary { return true }
                return false
            }

        var ordered = candidates
        if command.options.sorted || pruneActive {
            // Component-wise lexicographic order reproduces find -s (which sorts each
            // directory during traversal, so a directory's contents come before its
            // later siblings — plain string order differs at the '.' < '/' boundary).
            // -prune also needs parents processed before descendants, which this
            // order guarantees.
            ordered = Runner.findSorted(ordered)
        }
        if hasDelete {
            // Children before parents so rmdir succeeds.
            ordered.sort { ($0.depth, $1.path) > ($1.depth, $0.path) }
        }

        var prunedPrefixes: [String] = []
        for candidate in ordered {
            if pruneActive,
                prunedPrefixes.contains(where: { candidate.path.hasPrefix($0 + "/") })
            {
                continue
            }
            do {
                let outcome = try evaluator.process(candidate)
                if pruneActive, outcome.pruned, outcome.isDirectory {
                    prunedPrefixes.append(candidate.path)
                }
            } catch is QuitSignal {
                break
            } catch {
                sink.diagnostic("\(error)")
                sink.flush()
                return 1
            }
        }
        evaluator.finish()
        sink.flush()
        return evaluator.sawError ? 1 : 0
    }
}
