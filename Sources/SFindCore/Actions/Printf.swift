import Darwin
import Foundation

/// GNU find -printf directive formatting (sfind extension; macOS find has none).
struct PrintfFormat {
    struct Input {
        var path: String
        var depth: Int
        var info: FileInfo
        var linkTarget: String?
        var fstype: String
    }

    /// Renders `format` for one file. Returns the bytes to emit and whether \c
    /// requested an immediate stop of all output.
    static func render(
        _ format: String, input: Input, warn: (String) -> Void
    ) -> (bytes: [UInt8], stop: Bool) {
        var out = ""
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 1
                guard i < chars.count else {
                    out.append("\\")
                    break
                }
                switch chars[i] {
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "v": out.append("\u{0B}")
                case "\\": out.append("\\")
                case "c": return (Array(out.utf8), true)
                case "0"..."7":
                    var value = 0
                    var digits = 0
                    while i < chars.count, digits < 3, let d = chars[i].wholeNumberValue,
                        (0...7).contains(d)
                    {
                        value = value * 8 + d
                        digits += 1
                        i += 1
                    }
                    i -= 1
                    out.append(Character(UnicodeScalar(UInt8(value & 0xFF))))
                default:
                    warn("unrecognized escape \\\(chars[i])")
                    out.append("\\")
                    out.append(chars[i])
                }
                i += 1
                continue
            }
            if c != "%" {
                out.append(c)
                i += 1
                continue
            }
            // % [flags] [width] [.prec] directive
            i += 1
            guard i < chars.count else {
                out.append("%")
                break
            }
            var leftAlign = false
            while i < chars.count, "-+ 0#".contains(chars[i]) {
                if chars[i] == "-" { leftAlign = true }
                i += 1
            }
            var width = 0
            while i < chars.count, let d = chars[i].wholeNumberValue, chars[i].isNumber {
                width = width * 10 + d
                i += 1
            }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
            guard i < chars.count else { break }
            let directive = chars[i]
            i += 1
            var value: String
            switch directive {
            case "%": value = "%"
            case "p": value = input.path
            case "f": value = lastComponent(input.path)
            case "h": value = dirname(input.path)
            case "P": value = pathMinusRoot(input)
            case "H": value = rootOf(input)
            case "l": value = input.linkTarget ?? ""
            case "s": value = String(input.info.size)
            case "b": value = String(input.info.allocatedBlocks)
            case "k": value = String((input.info.allocatedBlocks * 512 + 1023) / 1024)
            case "S":
                let size = input.info.size
                let sparseness =
                    size == 0
                    ? 1.0 : Double(input.info.allocatedBlocks * 512) / Double(size)
                value = String(format: "%g", sparseness)
            case "y":
                value = input.info.fileType.map { String($0.rawValue) } ?? "?"
            case "Y":
                if input.info.isSymlink {
                    let resolved = FileInfo.statFollowing(input.path)
                    value =
                        resolved?.isSymlink == false
                        ? (resolved?.fileType.map { String($0.rawValue) } ?? "?") : "N"
                } else {
                    value = input.info.fileType.map { String($0.rawValue) } ?? "?"
                }
            case "m": value = String(input.info.permissionBits, radix: 8)
            case "M":
                var mode = [CChar](repeating: 0, count: 12)
                strmode(Int32(input.info.raw.st_mode), &mode)
                value = String(
                    decoding: mode.prefix(10).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            case "n": value = String(input.info.linkCount)
            case "i": value = String(input.info.inode)
            case "d": value = String(input.depth)
            case "D": value = String(input.info.device)
            case "F": value = input.fstype
            case "u":
                value =
                    getpwuid(input.info.uid).map { String(cString: $0.pointee.pw_name) }
                    ?? String(input.info.uid)
            case "U": value = String(input.info.uid)
            case "g":
                value =
                    getgrgid(input.info.gid).map { String(cString: $0.pointee.gr_name) }
                    ?? String(input.info.gid)
            case "G": value = String(input.info.gid)
            case "a", "c", "t":
                // ctime(3)-style fixed format.
                let field = timeField(directive)
                value = strftimeString("%a %b %e %H:%M:%S %Y", input.info.timespec(field))
            case "A", "B", "C", "T":
                // These always take a key character (GNU semantics; %B@ etc.).
                guard i < chars.count else {
                    warn("%\(directive) requires a format character")
                    value = ""
                    break
                }
                let k = chars[i]
                i += 1
                let field: TimeField
                switch directive {
                case "A": field = .access
                case "B": field = .birth
                case "C": field = .change
                default: field = .modify
                }
                value = timeWithKey(k, input.info.timespec(field))
            default:
                warn("unrecognized directive %\(directive)")
                value = "%\(directive)"
            }
            if width > 0 && value.count < width {
                let padding = String(repeating: " ", count: width - value.count)
                value = leftAlign ? value + padding : padding + value
            }
            out.append(value)
        }
        return (Array(out.utf8), false)
    }

    private static func timeField(_ c: Character) -> TimeField {
        switch c {
        case "a": return .access
        case "c": return .change
        case "B": return .birth
        default: return .modify
        }
    }

    private static func timeWithKey(_ key: Character, _ ts: timespec) -> String {
        if key == "@" {
            return "\(ts.tv_sec).\(String(format: "%09ld", ts.tv_nsec))0"
        }
        if key == "+" {
            return strftimeString("%Y-%m-%d+%H:%M:%S", ts)
        }
        return strftimeString("%\(key)", ts)
    }

    private static func strftimeString(_ format: String, _ ts: timespec) -> String {
        var t = time_t(ts.tv_sec)
        var tmValue = tm()
        localtime_r(&t, &tmValue)
        var buffer = [CChar](repeating: 0, count: 256)
        strftime(&buffer, buffer.count, format, &tmValue)
        return String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    private static func lastComponent(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    private static func dirname(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    /// The root operand is the path minus its last `depth` components.
    private static func rootOf(_ input: Input) -> String {
        guard input.depth > 0 else { return input.path }
        var path = Substring(input.path)
        for _ in 0..<input.depth {
            guard let slash = path.lastIndex(of: "/") else { break }
            path = path[..<slash]
        }
        return String(path)
    }

    private static func pathMinusRoot(_ input: Input) -> String {
        guard input.depth > 0 else { return "" }
        let root = rootOf(input)
        return String(input.path.dropFirst(root.count + 1))
    }
}
