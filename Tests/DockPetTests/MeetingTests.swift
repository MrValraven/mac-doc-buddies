//
//  MeetingTests.swift — [M11] occasions now, the meeting itself in Task 6.
//

import Foundation
import CoreGraphics
import DockPetCore

enum MeetingTests {

    /// Every date in this file is constructed explicitly. SPEC §9: a test that reads the
    /// system clock passes on 364 days and fails on the one that matters.
    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = m; components.day = d
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func run() {
        section("[M11] Occasion — birthday matching")

        eq(Occasion.isBirthday(date(2026, 8, 27), birthday: "08-27", calendar: utc), true,
           "the day itself matches")
        eq(Occasion.isBirthday(date(2026, 8, 26), birthday: "08-27", calendar: utc), false,
           "the day before does not")
        eq(Occasion.isBirthday(date(2027, 8, 27), birthday: "08-27", calendar: utc), true,
           "matches again the following year")
        eq(Occasion.isBirthday(date(2026, 8, 27), birthday: nil, calendar: utc), false,
           "no birthday configured is never a birthday")
        eq(Occasion.isBirthday(date(2026, 8, 27), birthday: "nonsense", calendar: utc), false,
           "an unparseable birthday is never a birthday, not a crash")
        eq(Occasion.isBirthday(date(2026, 8, 27), birthday: "8-27", calendar: utc), true,
           "a single-digit month is accepted")
        eq(Occasion.isBirthday(date(2024, 2, 29), birthday: "02-29", calendar: utc), true,
           "a leap day matches on a leap year")

        section("[M11] Occasion — day stamps")

        eq(Occasion.dayStamp(date(2026, 8, 27), calendar: utc), "2026-08-27",
           "a day stamp is zero-padded and sortable")
        check(Occasion.dayStamp(date(2026, 8, 27), calendar: utc)
              != Occasion.dayStamp(date(2026, 8, 28), calendar: utc),
              "consecutive days produce different stamps")
        eq(Occasion.dayStamp(date(2026, 8, 27), calendar: utc),
           Occasion.dayStamp(date(2026, 8, 27), calendar: utc),
           "the same day produces the same stamp")

        section("[M11] birthday lines")

        check(Phrasebook.birthdayLines.count >= 2,
              "the birthday pool has at least two lines, so it can avoid repeating")
        for line in Phrasebook.birthdayLines {
            let withName = Phrasebook.render(line, name: "Philippine")
            let without = Phrasebook.render(line, name: nil)
            check(!withName.contains(Phrasebook.nameSlot),
                  "the name slot is filled: \(withName)")
            check(!without.contains(Phrasebook.nameSlot),
                  "the name slot is removed: \(without)")
            check(!without.contains(" ,") && !without.contains("  ") && !without.hasPrefix(","),
                  "reads correctly with no name: \(without)")
            check(without.first.map { $0.isUppercase || $0.isPunctuation } ?? false,
                  "starts with a capital with no name: \(without)")
        }
    }
}
