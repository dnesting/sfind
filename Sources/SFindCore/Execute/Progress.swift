import Darwin
import Foundation

/// The --progress line: a bar with a best-effort completion estimate plus counters for
/// candidates received from the index query, candidates produced by the walk, entries
/// the walk scanned, candidates the post-filter rejected, and matches.
///
/// On a terminal the line redraws in place; elsewhere a newline-terminated status line
/// is emitted about once a second. The walk phases report a real fraction (a
/// hierarchical estimate from the traversal position); the index phase cannot know its
/// total in advance and shows an indeterminate marker. Main-thread only, like the rest
/// of the pipeline.
public final class Progress {
    public struct Counters: Equatable, Sendable {
        public var query = 0
        public var walk = 0
        public var scanned = 0
        public var filtered = 0
        public var matched = 0

        public init() {}
    }

    public var counters = Counters()

    private let write: ([UInt8]) -> Void
    private let terminal: Bool
    private let width: Int
    private let clock: () -> Double
    private let started: Double
    private var lastDraw: Double = -1
    private var phase = ""
    private var fraction: Double?
    private var spinnerStep = 0
    private var lineShowing = false
    private var finished = false

    /// `terminal` selects in-place redraws; `width` is the terminal's column count.
    public init(
        write: @escaping ([UInt8]) -> Void, terminal: Bool, width: Int = 80,
        clock: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.write = write
        self.terminal = terminal
        self.width = max(40, width)
        self.clock = clock
        self.started = clock()
    }

    /// A reporter on standard error, detecting whether it is a terminal.
    public static func standardError() -> Progress {
        let fd: Int32 = 2
        var size = winsize()
        let columns =
            ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
        return Progress(
            write: { bytes in
                bytes.withUnsafeBufferPointer { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let n = Darwin.write(
                            fd, buffer.baseAddress! + offset, buffer.count - offset)
                        if n <= 0 { break }
                        offset += n
                    }
                }
            },
            terminal: isatty(fd) == 1, width: columns)
    }

    /// A reporter that renders nothing but still accumulates counters (for --debug's
    /// final summary without --progress).
    public static func silent() -> Progress {
        Progress(write: { _ in }, terminal: false)
    }

    /// Names the current phase; `fraction` is nil when its extent is unknown.
    public func setPhase(_ label: String, fraction: Double?) {
        phase = label
        self.fraction = fraction
        redraw(force: true)
    }

    public func setFraction(_ fraction: Double?) {
        self.fraction = fraction
    }

    /// Redraws if enough time has passed (100ms on a terminal, 1s otherwise). Cheap
    /// enough to call per directory or per candidate.
    public func tick() {
        redraw(force: false)
    }

    /// Erases the in-place line so other output can take the terminal. The next tick
    /// redraws it.
    public func clearLine() {
        guard terminal, lineShowing else { return }
        write(Array("\r\u{1B}[K".utf8))
        lineShowing = false
    }

    /// Replaces the bar with a final summary line.
    public func finish() {
        guard !finished else { return }
        finished = true
        clearLine()
        write(Array(("sfind: " + summary() + "\n").utf8))
    }

    /// Runs `body` with a run-loop timer on the current thread that keeps the line
    /// animating while the caller waits inside CFRunLoopRun (the index phase).
    public func withRunLoopTimer<T>(_ body: () throws -> T) rethrows -> T {
        let runLoop = CFRunLoopGetCurrent()
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0
        ) { [weak self] _ in
            self?.tick()
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        defer { CFRunLoopRemoveTimer(runLoop, timer, .defaultMode) }
        return try body()
    }

    // MARK: - Rendering

    private func redraw(force: Bool) {
        guard !finished else { return }
        let now = clock()
        let interval = terminal ? 0.1 : 1.0
        guard force || lastDraw < 0 || now - lastDraw >= interval else { return }
        lastDraw = now
        spinnerStep += 1
        if terminal {
            var line = renderLine()
            if line.count >= width { line = String(line.prefix(width - 1)) }
            write(Array(("\r\u{1B}[K" + line).utf8))
            lineShowing = true
        } else {
            write(Array(("sfind: " + summary() + "\n").utf8))
        }
    }

    /// `[=====>     ]  42% walking · query 1,234 · walk 56 · filtered 900 · matched 300 · 1.3s`
    func renderLine() -> String {
        let barWidth = 20
        let bar: String
        let percent: String
        if let fraction {
            let clamped = min(max(fraction, 0), 1)
            let filled = Int((Double(barWidth) * clamped).rounded(.down))
            bar =
                String(repeating: "=", count: filled)
                + (filled < barWidth ? ">" : "")
                + String(repeating: " ", count: max(0, barWidth - filled - 1))
            percent = String(format: "%3d%%", Int((clamped * 100).rounded(.down)))
        } else {
            // Indeterminate: a marker bouncing across the bar.
            let span = barWidth - 3
            let step = spinnerStep % (2 * span)
            let position = step < span ? step : 2 * span - step
            bar =
                String(repeating: " ", count: position) + "<=>"
                + String(repeating: " ", count: span - position)
            percent = "  ?%"
        }
        return "[\(bar)] \(percent) \(summary())"
    }

    private func summary() -> String {
        var parts: [String] = []
        if !phase.isEmpty { parts.append(phase) }
        parts.append("query \(Progress.group(counters.query))")
        parts.append("walk \(Progress.group(counters.walk))")
        if counters.scanned > 0 {
            parts.append("scanned \(Progress.group(counters.scanned))")
        }
        parts.append("filtered \(Progress.group(counters.filtered))")
        parts.append("matched \(Progress.group(counters.matched))")
        parts.append(String(format: "%.1fs", clock() - started))
        return parts.joined(separator: " · ")
    }

    static func group(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }
}
