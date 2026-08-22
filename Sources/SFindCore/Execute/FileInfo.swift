import Darwin
import Foundation

/// A thin wrapper over stat(2)/lstat(2) results. Uses fstatat(2) because `stat` the C
/// function is shadowed by `stat` the struct in Swift's importer.
public struct FileInfo: Sendable {
    public var raw: stat

    public init(raw: stat) {
        self.raw = raw
    }

    /// lstat the given path (the -P default view of a file).
    public static func lstat(_ path: String) -> FileInfo? {
        var sb: stat = .init()
        guard fstatat(AT_FDCWD, path, &sb, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileInfo(raw: sb)
    }

    /// stat the given path, following symlinks; falls back to lstat for dangling links
    /// (the -L/-H behavior).
    public static func statFollowing(_ path: String) -> FileInfo? {
        var sb: stat = .init()
        if fstatat(AT_FDCWD, path, &sb, 0) == 0 {
            return FileInfo(raw: sb)
        }
        return lstat(path)
    }

    public var fileType: FileType? {
        switch raw.st_mode & S_IFMT {
        case S_IFBLK: return .block
        case S_IFCHR: return .character
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        case S_IFLNK: return .symlink
        case S_IFIFO: return .fifo
        case S_IFSOCK: return .socket
        case S_IFWHT: return .whiteout
        default: return nil
        }
    }

    public var isDirectory: Bool { raw.st_mode & S_IFMT == S_IFDIR }
    public var isRegular: Bool { raw.st_mode & S_IFMT == S_IFREG }
    public var isSymlink: Bool { raw.st_mode & S_IFMT == S_IFLNK }

    public var size: Int64 { raw.st_size }
    public var permissionBits: UInt16 { UInt16(raw.st_mode & 0o7777) }
    public var uid: UInt32 { raw.st_uid }
    public var gid: UInt32 { raw.st_gid }
    public var linkCount: UInt16 { UInt16(raw.st_nlink) }
    public var inode: UInt64 { raw.st_ino }
    public var device: Int32 { raw.st_dev }
    public var flags: UInt32 { raw.st_flags }
    public var allocatedBlocks: Int64 { Int64(raw.st_blocks) }

    public func timespec(_ field: TimeField) -> Darwin.timespec {
        switch field {
        case .access: return raw.st_atimespec
        case .birth: return raw.st_birthtimespec
        case .change: return raw.st_ctimespec
        case .modify: return raw.st_mtimespec
        }
    }

    public func date(_ field: TimeField) -> Date {
        let ts = timespec(field)
        return Date(
            timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}
