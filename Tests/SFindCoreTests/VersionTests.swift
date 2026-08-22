import SFindCore
import Testing

@Suite struct VersionTests {
    @Test func versionIsNonEmpty() {
        #expect(!SFind.version.isEmpty)
    }
}
