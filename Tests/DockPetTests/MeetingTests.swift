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

        section("[M11] Occasion — parse boundaries")

        eq(Occasion.parse("13-01") == nil, true, "a month above 12 is not a date")
        eq(Occasion.parse("00-15") == nil, true, "a month below 1 is not a date")
        eq(Occasion.parse("01-32") == nil, true, "a day above 31 is not a date")
        // Deliberate looseness, pinned rather than tightened: the range check is generic
        // (1...31), not per-month, so "02-30" parses even though no such date exists.
        // isBirthday compares against real DateComponents, so an impossible date simply
        // never matches a real day — cheaper than a calendar-aware check for the same result.
        check(Occasion.parse("02-30") != nil,
              "02-30 parses: the range check is generic, not per-month — a date that cannot "
              + "occur simply never matches a real day, which is cheaper than a "
              + "calendar-aware check")

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
            let withName = Phrasebook.render(line, name: "Sam")
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

        section("[M11] meeting — overlap")

        let left  = CGRect(x: 100, y: 0, width: 64, height: 64)
        let touching = CGRect(x: 160, y: 0, width: 64, height: 64)
        let apart = CGRect(x: 400, y: 0, width: 64, height: 64)

        eq(MeetingCoordinator.haveMet(left, touching), true, "overlapping frames have met")
        eq(MeetingCoordinator.haveMet(left, apart), false, "distant frames have not")
        eq(MeetingCoordinator.haveMet(touching, left), true, "the test is symmetric")
        eq(MeetingCoordinator.haveMet(left, left), true, "a frame meets itself")

        section("[M11] meeting — cooldown")

        do {
            var coordinator = MeetingCoordinator(seed: 42)
            // The cooldown starts elapsed, so the very first meeting is not swallowed.
            let first = coordinator.meet(left, touching, openerName: "Mochi", replierName: "Tigre")?.exchange
            check(first != nil, "the first meeting produces an exchange")

            let immediate = coordinator.meet(left, touching, openerName: "Mochi", replierName: "Tigre")?.exchange
            check(immediate == nil, "a second meeting during the cooldown produces nothing")

            // `advance` clamps a single call to `BehaviorMachine.maximumStep` (1 s), the
            // same bound `Walker` and `BehaviorMachine` use — so the elapsed cooldown is
            // simulated in small steps here, exactly as `StateMachineTests` simulates a
            // long duration for `BehaviorMachine` rather than handing it one huge `dt`.
            for _ in 0..<Int(MeetingCoordinator.cooldown - 1) {
                coordinator.advance(by: 1)
            }
            check(coordinator.meet(left, touching, openerName: "Mochi", replierName: "Tigre")?.exchange == nil,
                  "one second before the cooldown is up, still nothing")

            coordinator.advance(by: 1)
            check(coordinator.meet(left, touching, openerName: "Mochi", replierName: "Tigre")?.exchange != nil,
                  "once the cooldown is up, they meet again")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 42)
            check(coordinator.meet(left, apart, openerName: "Mochi", replierName: "Tigre")?.exchange == nil,
                  "pets that are not overlapping never meet, cooldown or not")
        }

        section("[M11] meeting — the exchange")

        do {
            var coordinator = MeetingCoordinator(seed: 7)
            guard let exchange = coordinator.meet(left, touching,
                                                  openerName: "Mochi",
                                                  replierName: "Tigre")?.exchange else {
                Harness.bail("expected an exchange from a fresh coordinator")
            }
            check(!exchange.opener.isEmpty, "the opener is not empty")
            check(!exchange.reply.isEmpty, "the reply is not empty")
            check(!exchange.opener.contains(Phrasebook.nameSlot), "the opener's slot is filled")
            check(!exchange.reply.contains(Phrasebook.nameSlot), "the reply's slot is filled")
        }

        do {
            // [R-review] seed 10 lands on meetingPairs[0], "Oh — hello, {name}." /
            // "Hello yourself, {name}." — a pair with {name} in *both* halves, so a name
            // swap inside meet() cannot hide behind a slot-free line. This replaces a
            // check that could never fail regardless of which name went where.
            var coordinator = MeetingCoordinator(seed: 10)
            guard let exchange = coordinator.meet(left, touching,
                                                  openerName: "Mochi",
                                                  replierName: "Tigre")?.exchange else {
                Harness.bail("expected an exchange from a fresh coordinator")
            }
            check(exchange.opener.contains("Tigre"), "the opener addresses the replier")
            check(exchange.reply.contains("Mochi"), "the reply addresses the opener")
        }

        do {
            // Determinism: same seed, same words. SPEC §9.
            var a = MeetingCoordinator(seed: 99)
            var b = MeetingCoordinator(seed: 99)
            let one = a.meet(left, touching, openerName: "M", replierName: "T")?.exchange
            let two = b.meet(left, touching, openerName: "M", replierName: "T")?.exchange
            eq(one?.opener, two?.opener, "the same seed picks the same opener")
            eq(one?.reply, two?.reply, "and the same reply")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 3)
            guard let nameless = coordinator.meet(left, touching,
                                                  openerName: nil,
                                                  replierName: nil)?.exchange else {
                Harness.bail("expected an exchange with no names")
            }
            check(!nameless.opener.contains(" ,") && !nameless.opener.contains("  "),
                  "the opener reads correctly with no names: \(nameless.opener)")
            check(!nameless.reply.contains(" ,") && !nameless.reply.contains("  "),
                  "the reply reads correctly with no names: \(nameless.reply)")
        }

        section("[M11] meeting — the pairs")

        check(Phrasebook.meetingPairs.count >= 2,
              "there are at least two pairs, so they do not always say the same thing")
        for pair in Phrasebook.meetingPairs {
            check(!pair.opener.isEmpty && !pair.reply.isEmpty, "both halves of a pair exist")
            for line in [pair.opener, pair.reply] {
                let without = Phrasebook.render(line, name: nil)
                check(!without.contains(Phrasebook.nameSlot),
                      "the slot is removed with no name: \(without)")
                check(!without.hasPrefix(",") && !without.contains("  "),
                      "reads correctly with no name: \(without)")
            }
        }
    }
}
