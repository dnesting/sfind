import Darwin
import Foundation

/// Formats -ls lines identically to /usr/bin/find's `ls -dgils` output:
/// `%6ju %8jd <strmode> %4ju %-16s %-16s %8jd <date> path[ -> target]`
/// (column widths verified against find with both small /dev inodes and large APFS
/// ones).
enum LsFormat {
    static let sixMonths: Int64 = (365 / 2) * 86400

    static func line(path: String, info: FileInfo, target: String?, nowSeconds: Int64) -> String {
        var mode = [CChar](repeating: 0, count: 12)
        strmode(Int32(info.raw.st_mode), &mode)
        let modeString = String(
            decoding: mode.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)

        let user: String
        if let pw = getpwuid(info.uid) {
            user = String(cString: pw.pointee.pw_name)
        } else {
            user = String(info.uid)
        }
        let group: String
        if let gr = getgrgid(info.gid) {
            group = String(cString: gr.pointee.gr_name)
        } else {
            group = String(info.gid)
        }

        let sizeField: String
        let fileKind = info.raw.st_mode & S_IFMT
        if fileKind == S_IFCHR || fileKind == S_IFBLK {
            sizeField = pad(String(format: "%#8x", info.raw.st_rdev), width: 8)
        } else {
            sizeField = pad(String(info.size), width: 8)
        }

        var line = pad(String(info.inode), width: 6)
        line += " " + pad(String(info.allocatedBlocks), width: 8)
        line += " " + modeString  // strmode includes the trailing attribute char.
        line += pad(String(info.linkCount), width: 4)
        line += " " + user.padding(toLength: 16, withPad: " ", startingAt: 0)
        line += " " + group.padding(toLength: 16, withPad: " ", startingAt: 0)
        line += " " + sizeField
        line += " " + timeField(seconds: Int64(info.raw.st_mtimespec.tv_sec), now: nowSeconds)
        line += " " + path
        if let target {
            line += " -> " + target
        }
        return line
    }

    /// `%b %e %H:%M` within ±6 months of now, else `%b %e  %Y` (find behavior).
    static func timeField(seconds: Int64, now: Int64) -> String {
        var t = time_t(seconds)
        var tmValue = tm()
        localtime_r(&t, &tmValue)
        let recent = seconds + sixMonths > now && seconds < now + sixMonths
        var buffer = [CChar](repeating: 0, count: 64)
        strftime(&buffer, buffer.count, recent ? "%b %e %H:%M" : "%b %e  %Y", &tmValue)
        return String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    private static func pad(_ s: String, width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
}
