import Foundation

/// Parses the date strings accepted by -newerXt. macOS find uses a lenient
/// getdate-style parser; sfind supports the common forms (ISO 8601 with or without
/// time, a space or T separator, RFC 2822, `MMM d yyyy`, and the relative words
/// `now`/`today`/`yesterday` plus `N <unit>[s] ago`). As an extension, GNU's
/// `@epoch` form is also accepted.
public enum DateParser {
    public static func parse(_ input: String, now: Date = Date()) -> Date? {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }

        switch text.lowercased() {
        case "now": return now
        case "today": return Calendar.current.startOfDay(for: now)
        case "yesterday":
            return Calendar.current.startOfDay(for: now).addingTimeInterval(-86400)
        default: break
        }

        // GNU @epoch extension.
        if text.hasPrefix("@"), let epoch = Double(text.dropFirst()) {
            return Date(timeIntervalSince1970: epoch)
        }

        // "N <unit>[s] ago"
        if text.lowercased().hasSuffix(" ago") {
            let parts = text.dropLast(4).split(separator: " ")
            if parts.count == 2, let n = Double(parts[0]) {
                let unit: TimeInterval?
                switch parts[1].lowercased() {
                case "second", "seconds": unit = 1
                case "minute", "minutes": unit = 60
                case "hour", "hours": unit = 3600
                case "day", "days": unit = 86400
                case "week", "weeks": unit = 604_800
                default: unit = nil
                }
                if let unit { return now.addingTimeInterval(-n * unit) }
            }
        }

        for format in [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "EEE, d MMM yyyy HH:mm:ss ZZZ",
            "MMM d yyyy",
            "MMM d, yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
