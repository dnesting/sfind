import Foundation
import SFindCore
import Testing

@Suite struct TypeSizeFilterTests {
    @Test func typeLetters() throws {
        let tree = try TempTree()
        try tree.file("regular")
        try tree.dir("folder")
        try tree.symlink("link", to: "regular")
        #expect(try Filter.relativeMatches(["-type", "f"], in: tree) == ["regular"])
        #expect(try Filter.relativeMatches(["-type", "d"], in: tree) == [".", "folder"])
        #expect(try Filter.relativeMatches(["-type", "l"], in: tree) == ["link"])
    }

    @Test func symlinkModesChangeTypeResults() throws {
        let tree = try TempTree()
        try tree.dir("realdir")
        try tree.symlink("dirlink", to: "realdir")
        // -P (default): the link is a link.
        #expect(try Filter.relativeMatches(["-type", "l"], in: tree) == ["dirlink"])
        // -L: the link resolves to a directory; only broken links stay links.
        #expect(
            try Filter.relativeMatches(["-L", "-type", "d"], in: tree)
                == [".", "dirlink", "realdir"])
        #expect(try Filter.relativeMatches(["-L", "-type", "l"], in: tree) == [])
        // -H: follows only command-line operands; dirlink is below the root.
        #expect(try Filter.relativeMatches(["-H", "-type", "l"], in: tree) == ["dirlink"])
    }

    @Test func brokenLinkUnderLRemainsALink() throws {
        let tree = try TempTree()
        try tree.symlink("broken", to: "does-not-exist")
        #expect(try Filter.relativeMatches(["-L", "-type", "l"], in: tree) == ["broken"])
    }

    @Test func sizeBlocksRoundUp() throws {
        // The verified case: 27034 bytes rounds up to 53 blocks.
        let tree = try TempTree()
        try tree.file("f", size: 27034)
        #expect(try Filter.relativeMatches(["-size", "53", "-type", "f"], in: tree) == ["f"])
        #expect(try Filter.relativeMatches(["-size", "52", "-type", "f"], in: tree) == [])
        #expect(try Filter.relativeMatches(["-size", "54", "-type", "f"], in: tree) == [])
        #expect(try Filter.relativeMatches(["-size", "+52", "-type", "f"], in: tree) == ["f"])
        #expect(try Filter.relativeMatches(["-size", "-54", "-type", "f"], in: tree) == ["f"])
    }

    @Test func sizeSuffixesAreExactBytes() throws {
        // Verified macOS semantics: scaled suffixes compare exact bytes, no rounding.
        let tree = try TempTree()
        try tree.file("f", size: 27034)
        #expect(try Filter.relativeMatches(["-size", "27034c", "-type", "f"], in: tree) == ["f"])
        #expect(try Filter.relativeMatches(["-size", "27k", "-type", "f"], in: tree) == [])
        #expect(try Filter.relativeMatches(["-size", "+26k", "-type", "f"], in: tree) == ["f"])
        #expect(try Filter.relativeMatches(["-size", "-27k", "-type", "f"], in: tree) == ["f"])
    }

    @Test func emptyFilesAndDirectories() throws {
        let tree = try TempTree()
        try tree.file("zero")
        try tree.file("full", size: 10)
        try tree.dir("emptydir")
        try tree.dir("fulldir")
        try tree.file("fulldir/x", size: 1)
        #expect(try Filter.relativeMatches(["-empty"], in: tree) == ["emptydir", "zero"])
    }

    @Test func linksAndInum() throws {
        let tree = try TempTree()
        let original = try tree.file("original")
        try FileManager.default.linkItem(atPath: original, toPath: tree.root + "/hardlink")
        #expect(
            try Filter.relativeMatches(["-type", "f", "-links", "2"], in: tree)
                == ["hardlink", "original"])
        #expect(try Filter.relativeMatches(["-type", "f", "-links", "1"], in: tree) == [])
        guard let info = FileInfo.lstat(original) else {
            Issue.record("lstat failed")
            return
        }
        #expect(
            try Filter.relativeMatches(["-inum", "\(info.inode)"], in: tree)
                == ["hardlink", "original"])
    }

    @Test func samefile() throws {
        let tree = try TempTree()
        let original = try tree.file("original")
        try FileManager.default.linkItem(atPath: original, toPath: tree.root + "/hardlink")
        try tree.file("unrelated")
        #expect(
            try Filter.relativeMatches(["-samefile", original], in: tree)
                == ["hardlink", "original"])
    }
}
