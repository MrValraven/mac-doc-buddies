//
//  Meeting.swift — [M11] when two pets have met, what they trade, and what day it is.
//
//  SPEC §5: no AppKit. SPEC §9: every date is a parameter, never `Date()` read inside a
//  function under test — a birthday feature that can only be tested on the birthday is
//  not tested.
//

import CoreGraphics
import Foundation

/// Days the pet knows about.
public enum Occasion {

    /// Is `date` the birthday written in the config?
    ///
    /// `birthday` is `"MM-DD"`. It is parsed leniently — `"8-27"` works — and anything
    /// that does not parse is simply not a birthday, per §1's rule that a bad value costs
    /// a log line rather than a launch.
    public static func isBirthday(_ date: Date, birthday: String?,
                                  calendar: Calendar = .current) -> Bool {
        guard let birthday, let (month, day) = parse(birthday) else { return false }
        let components = calendar.dateComponents([.month, .day], from: date)
        return components.month == month && components.day == day
    }

    /// `"MM-DD"` to numbers, or `nil` if it is not that.
    ///
    /// Range-checked rather than merely numeric: `"13-40"` parses as two integers and is
    /// still not a date, and silently matching nothing forever is a worse answer than
    /// rejecting it here where the config validator can report it.
    public static func parse(_ birthday: String) -> (month: Int, day: Int)? {
        let parts = birthday.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]), let day = Int(parts[1]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (month, day)
    }

    /// A sortable stamp for "which day is it", used to fire once-a-day behaviour.
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` so it cannot pick up a
    /// locale's calendar or numerals — this string is compared against one written to disk
    /// weeks earlier, possibly under different system settings.
    public static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
