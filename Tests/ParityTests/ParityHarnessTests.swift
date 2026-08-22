import Foundation
import SFindCore
import Testing

/// Parity tests run /usr/bin/find against sfind's filter+action machinery over a walked
/// fixture tree (no Spotlight involvement), so they can run anywhere — including tmp
/// directories and CI. Cases are added per SPEC.md entry as options are implemented.
@Suite struct ParityHarnessTests {
    @Test func findOracleIsAvailable() throws {
        #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/find"))
    }
}
