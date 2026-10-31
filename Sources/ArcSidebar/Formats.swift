import Foundation

/// Dates, times and durations in one style: day and month order follow the
/// system language, but times are always 24-hour ("14:30"), weeks start on Monday and are ISO
/// weeks, durations read "45 min" or "1 h 30", never "1.5 h" or "90:00".
enum Formats {
    /// ISO 8601: Monday first, week 1 is the one with the year's first Thursday.
    static func calendar(locale: Locale = .current) -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.locale = locale
        c.timeZone = .current
        return c
    }

    private static func formatter(_ template: String, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar(locale: locale)
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "14:30"
    static func time(_ date: Date, locale: Locale = .current) -> String {
        formatter("HHmm", locale: locale).string(from: date)
    }

    /// "Thu 29 Oct" (order and punctuation from the system language).
    static func shortDay(_ date: Date, locale: Locale = .current) -> String {
        formatter("EEEdMMM", locale: locale).string(from: date)
    }

    /// "29.10.2026" in German, "29/10/2026" in British English.
    static func date(_ date: Date, locale: Locale = .current) -> String {
        formatter("ddMMyyyy", locale: locale).string(from: date)
    }

    /// "Today", "Yesterday", "Tomorrow", else the short day; for lists (absolute dates in details).
    static func relativeDay(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let c = calendar(locale: locale)
        if c.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if let t = c.date(byAdding: .day, value: 1, to: now), c.isDate(date, inSameDayAs: t) { return "Tomorrow" }
        return shortDay(date, locale: locale)
    }

    /// "Thu 29 Oct 2026, 14:30" for stamps in files.
    static func stamp(_ date: Date, locale: Locale = .current) -> String {
        formatter("EEEdMMMyyyy", locale: locale).string(from: date) + ", " + time(date, locale: locale)
    }

    /// "45 min", "1 h", "1 h 30", "2 days".
    static func duration(minutes: Int) -> String {
        switch minutes {
        case ..<60: return "\(minutes) min"
        case ..<1440: return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
        default:
            if minutes % 1440 == 0 { return minutes == 1440 ? "1 day" : "\(minutes / 1440) days" }
            return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
        }
    }
}
