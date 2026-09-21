import Foundation
import SFindCore
import Testing

/// Progress rendering observed through the injected `write` closure with a controlled
/// clock.
@Suite struct ProgressTests {
    static let erase = "\r\u{1B}[K"

    /// A collector of everything written, split per write call, with a settable clock.
    final class Capture {
        var writes: [String] = []
        var now = 0.0

        var text: String { writes.joined() }

        func progress(terminal: Bool, width: Int = 80) -> SFindCore.Progress {
            SFindCore.Progress(
                write: { [self] bytes in self.writes.append(String(decoding: bytes, as: UTF8.self))
                },
                terminal: terminal, width: width, clock: { [self] in self.now })
        }
    }

    @Test func terminalLinesRedrawInPlace() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.setPhase("walking", fraction: 0.5)
        #expect(capture.writes.count == 1)
        let line = try! #require(capture.writes.first)
        #expect(line.hasPrefix(Self.erase + "["))
        #expect(line.contains(" 50% "))
        #expect(line.contains("walking"))
        #expect(!line.hasSuffix("\n"))
    }

    @Test func fractionRendersPercentAndBar() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.setPhase("walking", fraction: 0)
        #expect(capture.writes.last?.contains("[>                   ]   0%") == true)
        progress.setPhase("walking", fraction: 0.5)
        #expect(capture.writes.last?.contains("[==========>         ]  50%") == true)
        progress.setPhase("walking", fraction: 1)
        #expect(capture.writes.last?.contains("[====================] 100%") == true)
        // Out-of-range fractions clamp.
        progress.setPhase("walking", fraction: 7)
        #expect(capture.writes.last?.contains("100%") == true)
    }

    @Test func unknownFractionRendersIndeterminateMarker() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.setPhase("querying index", fraction: nil)
        let line = try! #require(capture.writes.last)
        #expect(line.contains("?%"))
        #expect(line.contains("<=>"))
        #expect(!line.contains("50%"))
    }

    @Test func countersUseThousandsGrouping() {
        let capture = Capture()
        let progress = capture.progress(terminal: true, width: 200)
        progress.counters.query = 1234
        progress.counters.walk = 56
        progress.counters.scanned = 1_000_000
        progress.counters.filtered = 900
        progress.counters.matched = 300
        progress.tick()
        let line = try! #require(capture.writes.last)
        #expect(line.contains("query 1,234"))
        #expect(line.contains("walk 56"))
        #expect(line.contains("scanned 1,000,000"))
        #expect(line.contains("filtered 900"))
        #expect(line.contains("matched 300"))
    }

    @Test func scannedCounterAppearsOnlyWhenNonzero() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.tick()
        #expect(capture.writes.last?.contains("scanned") == false)
    }

    @Test func terminalTicksAreThrottled() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.tick()
        #expect(capture.writes.count == 1)
        capture.now = 0.05
        progress.tick()
        #expect(capture.writes.count == 1)
        capture.now = 0.1
        progress.tick()
        #expect(capture.writes.count == 2)
        // setPhase always redraws.
        progress.setPhase("walking", fraction: 0)
        #expect(capture.writes.count == 3)
        // setFraction alone does not.
        progress.setFraction(0.9)
        #expect(capture.writes.count == 3)
    }

    @Test func nonTerminalEmitsLinesAtMostOncePerSecond() {
        let capture = Capture()
        let progress = capture.progress(terminal: false)
        progress.setPhase("walking", fraction: 0.25)
        for step in 1...9 {
            capture.now = Double(step) / 10
            progress.tick()
        }
        #expect(capture.writes.count == 1)
        capture.now = 1.0
        progress.tick()
        #expect(capture.writes.count == 2)
        capture.now = 1.5
        progress.tick()
        #expect(capture.writes.count == 2)
        capture.now = 2.0
        progress.tick()
        #expect(capture.writes.count == 3)
        for line in capture.writes {
            #expect(line.hasPrefix("sfind: "))
            #expect(line.hasSuffix("\n"))
            #expect(!line.contains("\u{1B}"))
            #expect(!line.contains("%"))
        }
    }

    @Test func elapsedTimeComesFromClock() {
        let capture = Capture()
        capture.now = 10
        let progress = capture.progress(terminal: false)
        capture.now = 11.3
        progress.tick()
        #expect(capture.writes.last?.contains("1.3s") == true)
    }

    @Test func finishWritesSummaryAndSilencesLaterTicks() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.setPhase("walking", fraction: 0.5)
        progress.counters.matched = 3
        progress.finish()
        let last = try! #require(capture.writes.last)
        #expect(last.hasPrefix("sfind: "))
        #expect(last.hasSuffix("\n"))
        #expect(last.contains("matched 3"))
        // The in-place line is erased before the summary.
        #expect(capture.writes.dropLast().last == Self.erase)

        let count = capture.writes.count
        capture.now = 5
        progress.tick()
        progress.setPhase("again", fraction: 1)
        progress.finish()
        #expect(capture.writes.count == count)
    }

    @Test func finishOnNonTerminalWritesOneSummary() {
        let capture = Capture()
        let progress = capture.progress(terminal: false)
        progress.finish()
        #expect(capture.writes.count == 1)
        #expect(capture.writes.first?.hasPrefix("sfind: ") == true)
        progress.finish()
        #expect(capture.writes.count == 1)
    }

    @Test func clearLineErasesOnlyWhenShowing() {
        let capture = Capture()
        let progress = capture.progress(terminal: true)
        progress.clearLine()
        #expect(capture.writes.isEmpty)
        progress.setPhase("walking", fraction: 0)
        progress.clearLine()
        #expect(capture.writes.last == Self.erase)
        let count = capture.writes.count
        progress.clearLine()
        #expect(capture.writes.count == count)
        // The next forced redraw shows the line again.
        progress.setPhase("walking", fraction: 0.1)
        progress.clearLine()
        #expect(capture.writes.count == count + 2)
        #expect(capture.writes.last == Self.erase)
    }

    @Test func clearLineIsInertOffTerminal() {
        let capture = Capture()
        let progress = capture.progress(terminal: false)
        progress.setPhase("walking", fraction: 0)
        progress.clearLine()
        #expect(capture.writes.count == 1)
        #expect(!capture.text.contains(Self.erase))
    }

    @Test func terminalLineIsTruncatedToWidth() {
        let capture = Capture()
        let progress = capture.progress(terminal: true, width: 40)
        progress.counters.query = 123_456_789
        progress.counters.filtered = 987_654_321
        progress.setPhase("querying index", fraction: nil)
        let line = try! #require(capture.writes.last)
        #expect(line.dropFirst(Self.erase.count).count < 40)
    }

    @Test func widthHasAFloor() {
        let capture = Capture()
        let progress = capture.progress(terminal: true, width: 5)
        progress.setPhase("w", fraction: 0)
        let line = try! #require(capture.writes.last)
        #expect(line.dropFirst(Self.erase.count).count < 40)
        #expect(line.dropFirst(Self.erase.count).count > 20)
    }
}
