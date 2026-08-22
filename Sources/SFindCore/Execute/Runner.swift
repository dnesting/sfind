import Foundation

/// Drives candidates from a source through the evaluator, honoring -s ordering and
/// -quit, and produces find-compatible exit status (0 iff no errors; match count is
/// irrelevant).
public final class Runner {
    let command: ParsedCommand
    let environment: PlannerEnvironment
    let sink: OutputSink

    public init(command: ParsedCommand, environment: PlannerEnvironment, sink: OutputSink) {
        self.command = command
        self.environment = environment
        self.sink = sink
    }

    public func run(source: CandidateSource) -> Int32 {
        let evaluator: Evaluator
        let candidates: [Candidate]
        do {
            evaluator = try Evaluator(command: command, environment: environment, sink: sink)
            candidates = try source.candidates()
        } catch {
            sink.diagnostic("\(error)")
            sink.flush()
            return 1
        }

        var ordered = candidates
        if command.options.sorted {
            ordered.sort { $0.path < $1.path }
        }

        for candidate in ordered {
            do {
                try evaluator.process(candidate)
            } catch is QuitSignal {
                break
            } catch {
                sink.diagnostic("\(error)")
                sink.flush()
                return 1
            }
        }
        sink.flush()
        return evaluator.sawError ? 1 : 0
    }
}
