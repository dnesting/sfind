import Foundation

/// The --debug channel: `sfind: debug: …` lines on standard error explaining where
/// the search looks (roots, query, scope, walk phases) and what each stage produced,
/// so an unexpected result — typically an empty one — can be traced to its cause.
public final class DebugLog {
    private let sink: OutputSink
    public let started = Date()

    public init(sink: OutputSink) {
        self.sink = sink
    }

    public func log(_ message: String) {
        sink.diagnostic("debug: \(message)")
    }

    /// `1.23s` since `date` (or since the log was created).
    public func elapsed(since date: Date? = nil) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(date ?? started))
    }

    /// Up to `limit` items, then "(+N more)".
    public static func list(_ items: [String], limit: Int = 5) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown) (+\(items.count - limit) more)" : shown
    }

    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(Progress.group(n)) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
