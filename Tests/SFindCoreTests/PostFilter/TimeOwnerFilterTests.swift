import Darwin
import Foundation
import SFindCore
import Testing

@Suite struct TimeOwnerFilterTests {
    let now = Date()

    @Test func mtimeDaysUseFloor() throws {
        let tree = try TempTree()
        try tree.file("h23", mtime: now.addingTimeInterval(-23 * 3600))
        try tree.file("h25", mtime: now.addingTimeInterval(-25 * 3600))
        try tree.file("h47", mtime: now.addingTimeInterval(-47 * 3600))
        // floor(age/86400): 23h→0, 25h→1, 47h→1 (verified against find).
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "0"], in: tree, now: now)
                == ["h23"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "1"], in: tree, now: now)
                == ["h25", "h47"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "-1"], in: tree, now: now)
                == ["h23"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "+0"], in: tree, now: now)
                == ["h25", "h47"])
    }

    @Test func mminUsesCeil() throws {
        let tree = try TempTree()
        try tree.file("m59s30", mtime: now.addingTimeInterval(-(59 * 60 + 30)))
        // ceil(age/60): 59m30s → 60 (verified against find).
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mmin", "60"], in: tree, now: now)
                == ["m59s30"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mmin", "59"], in: tree, now: now) == [])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mmin", "-61"], in: tree, now: now)
                == ["m59s30"])
    }

    @Test func unitSuffixesCompareRawSeconds() throws {
        let tree = try TempTree()
        try tree.file("h23", mtime: now.addingTimeInterval(-23 * 3600))
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "-23h30m"], in: tree, now: now)
                == ["h23"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-mtime", "+23h30m"], in: tree, now: now)
                == [])
    }

    @Test func newerComparesAgainstReferenceFile() throws {
        let tree = try TempTree()
        try tree.file("older", mtime: now.addingTimeInterval(-300))
        let reference = try tree.file("ref", mtime: now.addingTimeInterval(-200))
        try tree.file("newer", mtime: now.addingTimeInterval(-100))
        #expect(
            try Filter.relativeMatches(["-type", "f", "-newer", reference], in: tree, now: now)
                == ["newer"])
        #expect(
            try Filter.relativeMatches(
                ["-type", "f", "!", "-newer", reference], in: tree, now: now)
                == ["older", "ref"])
    }

    @Test func newerWithDateString() throws {
        let tree = try TempTree()
        try tree.file("f", mtime: now.addingTimeInterval(-30))
        #expect(
            try Filter.relativeMatches(
                ["-type", "f", "-newermt", "1 hour ago"], in: tree, now: now) == ["f"])
        #expect(
            try Filter.relativeMatches(
                ["-type", "f", "-newermt", "2050-01-01"], in: tree, now: now) == [])
    }

    @Test func ownershipMatchesCurrentUser() throws {
        let tree = try TempTree()
        try tree.file("mine")
        let uid = getuid()
        let gid = getgid()
        #expect(
            try Filter.relativeMatches(["-type", "f", "-user", "\(uid)"], in: tree) == ["mine"])
        #expect(
            try Filter.relativeMatches(["-type", "f", "-group", "\(gid)"], in: tree) == ["mine"])
        #expect(try Filter.relativeMatches(["-type", "f", "-nouser"], in: tree) == [])
        let name = String(cString: getpwuid(uid).pointee.pw_name)
        #expect(
            try Filter.relativeMatches(["-type", "f", "-user", name], in: tree) == ["mine"])
    }

    @Test func permMatching() throws {
        let tree = try TempTree()
        try tree.file("rw", mode: 0o644)
        try tree.file("rwx", mode: 0o755)
        try tree.file("locked", mode: 0o400)
        let files = { (tokens: [String]) in
            try Filter.relativeMatches(["-type", "f"] + tokens, in: tree)
        }
        #expect(try files(["-perm", "644"]) == ["rw"])
        #expect(try files(["-perm", "-644"]) == ["rw", "rwx"])
        #expect(try files(["-perm", "+111"]) == ["rwx"])
        #expect(try files(["-perm", "/111"]) == ["rwx"])
        #expect(try files(["-perm", "-u+w"]) == ["rw", "rwx"])
        #expect(try files(["-perm", "400"]) == ["locked"])
    }

    @Test func accessExtensions() throws {
        let tree = try TempTree()
        try tree.file("open", mode: 0o644)
        try tree.file("exec", mode: 0o755)
        let files = { (tokens: [String]) in
            try Filter.relativeMatches(["-type", "f"] + tokens, in: tree)
        }
        #expect(try files(["-readable"]) == ["exec", "open"])
        #expect(try files(["-writable"]) == ["exec", "open"])
        #expect(try files(["-executable"]) == ["exec"])
    }

    @Test func xattrPredicates() throws {
        let tree = try TempTree()
        let path = try tree.file("tagged")
        try tree.file("plain")
        let value: [UInt8] = [1, 2, 3]
        #expect(setxattr(path, "sfind.test", value, value.count, 0, 0) == 0)
        let files = { (tokens: [String]) in
            try Filter.relativeMatches(["-type", "f"] + tokens, in: tree)
        }
        // The OS may stamp its own xattrs (e.g. com.apple.provenance) on new files,
        // so assert membership rather than the exact -xattr set.
        #expect(try files(["-xattr"]).contains("tagged"))
        #expect(try files(["-xattrname", "sfind.test"]) == ["tagged"])
        #expect(try files(["-xattrname", "other.name"]) == [])
    }
}
