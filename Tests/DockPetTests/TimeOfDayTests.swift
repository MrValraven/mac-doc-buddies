//
//  TimeOfDayTests.swift: [M13] assertions for DockPetCore.TimeOfDay and the time-aware
//  greeting.
//
//  Two things are worth pinning down here, and they are the two nobody can check by
//  clicking the cat: the hour boundaries land where they are documented to land, on both
//  sides and across midnight, and every greeting added for this feature still obeys the
//  M10 name-slot rule, which is only visible when there is no name to put in the slot.
//
//  Every date below is built from an explicit gregorian calendar pinned to UTC and handed
//  to the code under test. SPEC §9: a greeting that can only be checked at 8am is not
//  checked, and one that passes only in this machine's time zone is worse than that.
//

import Foundation
import DockPetCore

enum TimeOfDayTests {

    /// Fixed calendar for every date in this file.
    ///
    /// UTC rather than the machine's zone, so the hour a test writes is the hour the code
    /// reads. `Calendar.current` would also make the 02:00 checks unrunnable on the one
    /// spring morning a year that has no 02:00 in the local zone.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// A date on a fixed, unremarkable day, 14 March 2026, at the given wall-clock time.
    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else {
            Harness.bail("could not build \(hour):\(minute) on 2026-03-\(day)")
        }
        return date
    }

    private static func time(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
        TimeOfDay.at(at(hour, minute), calendar: calendar)
    }

    static func run() {

        section("time of day: the boundaries, from both sides")

        // 05:00 opens the morning. Anyone awake at 04:59 has not started the day, they
        // have not finished the previous one.
        eq(time(4, 59), .night, "04:59 is still night")
        eq(time(5, 0), .morning, "05:00 is morning")

        // Noon, which needs no defending.
        eq(time(11, 59), .morning, "11:59 is still morning")
        eq(time(12, 0), .afternoon, "12:00 is afternoon")

        // 17:00, the hour the working afternoon stops being one.
        eq(time(16, 59), .afternoon, "16:59 is still afternoon")
        eq(time(17, 0), .evening, "17:00 is evening")

        // 22:00, late enough that "still up?" is an observation rather than a comment.
        eq(time(21, 59), .evening, "21:59 is still evening")
        eq(time(22, 0), .night, "22:00 is night")

        section("time of day: midnight")

        eq(time(23, 0), .night, "23:00 is night")
        eq(time(23, 59), .night, "23:59 is night")
        eq(time(0, 0), .night, "00:00 is night")
        eq(time(0, 1), .night, "00:01 is night")
        eq(time(3, 0), .night, "03:00 is night, one stretch with the 23:00 before it")

        // The rollover itself: sixty seconds apart, a different calendar day, the same word
        // for it. Night is the only case that has to survive the date changing underneath
        // it, so this is the check that would catch it being written as a range that
        // silently stops at 23:59.
        let lateNight = at(23, 59)
        let justAfterMidnight = lateNight.addingTimeInterval(60)
        check(Occasion.dayStamp(lateNight, calendar: calendar)
              != Occasion.dayStamp(justAfterMidnight, calendar: calendar),
              "the two sides of the rollover really are different days",
              detail: Occasion.dayStamp(justAfterMidnight, calendar: calendar))
        eq(TimeOfDay.at(lateNight, calendar: calendar), .night, "23:59 is night")
        eq(TimeOfDay.at(justAfterMidnight, calendar: calendar), .night,
           "and 00:00, sixty seconds later, is the same night")

        section("time of day: the whole day is covered")

        var seen = Set<TimeOfDay>()
        for hour in 0..<24 { seen.insert(time(hour)) }
        eq(seen.count, TimeOfDay.allCases.count,
           "every case is reachable from some hour of the day")
        check(TimeOfDay.allCases.count == 4, "there are four parts to a day",
              detail: "got \(TimeOfDay.allCases.count)")

        let nightHours = (0..<24).filter { time($0) == .night }
        check(nightHours == [0, 1, 2, 3, 4, 22, 23],
              "night is 22:00 to 04:59, wrapping through midnight",
              detail: "got \(nightHours)")

        section("greetings: a pool for each part of the day")

        for part in TimeOfDay.allCases {
            let specific = Phrasebook.timeGreetings(for: part)
            let pool = Phrasebook.greetingLines(for: part)

            check(specific.count >= 2,
                  "\(part.rawValue) has at least two lines of its own",
                  detail: "got \(specific.count)")
            check(pool.count >= 2,
                  "\(part.rawValue) can greet twice without repeating itself",
                  detail: "got \(pool.count)")
            check(specific.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                  "\(part.rawValue) has no blank greetings")
            check(Set(pool).count == pool.count, "\(part.rawValue) has no duplicate greetings")
            check(specific.allSatisfy { $0.contains(Phrasebook.nameSlot) },
                  "every \(part.rawValue) greeting has a name slot to fill")
            check(Phrasebook.anytimeGreetings.allSatisfy { pool.contains($0) },
                  "\(part.rawValue) still says the greetings that fit at any hour")
        }

        // Equal pool sizes are not cosmetic: `reply` draws an index, so pools of the same
        // length give it the same sequence of draws whatever the hour. Without this, a
        // reachability check like the one further down could pass in the morning and fail
        // at night, which is the worst kind of test.
        let sizes = Set(TimeOfDay.allCases.map { Phrasebook.greetingLines(for: $0).count })
        check(sizes.count == 1, "every part of the day has the same number of greetings",
              detail: "got \(sizes.sorted())")

        // No time-specific line is shared between two parts of the day. A line that turns
        // up at 8am and again at 1am is the exact thing this feature exists to stop.
        let specificEverywhere = TimeOfDay.allCases.flatMap { Phrasebook.timeGreetings(for: $0) }
        eq(Set(specificEverywhere).count, specificEverywhere.count,
           "no time-specific greeting is shared between two parts of the day")
        check(Set(specificEverywhere).isDisjoint(with: Set(Phrasebook.anytimeGreetings)),
              "and none of them is an evergreen line wearing a hat")

        section("greetings: the M10 name-slot rule")

        // The rule every new line is written to: it must read correctly with the name taken
        // out, because `userName: ""` is a supported setting and the account name can be
        // missing. `render` does the surgery; these are the scars it leaves when a line was
        // written carelessly, a stranded comma, a doubled space, or a sentence that now
        // opens with its own punctuation.
        //
        // Applied to the time-specific lines, which are this feature's. The evergreen pool
        // predates it and is checked, as it always was, by PhrasebookTests.
        for part in TimeOfDay.allCases {
            for template in Phrasebook.timeGreetings(for: part) {
                let withName = Phrasebook.render(template, name: "Sam")
                let without = Phrasebook.render(template, name: nil)
                let which = "\(part.rawValue): \"\(template)\""

                check(!withName.contains(Phrasebook.nameSlot), "\(which) fills its slot")
                check(withName.contains("Sam"), "\(which) actually says the name")
                check(!without.contains(Phrasebook.nameSlot),
                      "\(which) drops its slot with no name")
                check(!without.isEmpty, "\(which) is not empty without a name")
                check(!without.contains("  "), "\(which) leaves no doubled space")
                check(!without.contains(" ,") && !without.contains(" ."),
                      "\(which) strands no punctuation", detail: without)
                check(without == without.trimmingCharacters(in: .whitespaces),
                      "\(which) has no edge whitespace")
                check(without.first?.isLetter == true && without.first?.isUppercase == true,
                      "\(which) still opens with a capital letter", detail: without)
                check(!template.contains("\u{2014}"), "\(which) uses no em dash")
            }
        }

        section("greetings: hello follows the clock")

        let morning = at(8)
        let night = at(1)

        check(Phrasebook.lines(for: .hello, at: morning, calendar: calendar)
              == Phrasebook.greetingLines(for: .morning),
              "the hello pool at 08:00 is the morning pool")
        check(Phrasebook.lines(for: .hello, at: night, calendar: calendar)
              == Phrasebook.greetingLines(for: .night),
              "the hello pool at 01:00 is the night pool")

        var book = Phrasebook(seed: 21)
        let morningPool = Set(Phrasebook.greetingLines(for: .morning).map {
            Phrasebook.render($0, name: "Sam")
        })
        let nightPool = Set(Phrasebook.greetingLines(for: .night).map {
            Phrasebook.render($0, name: "Sam")
        })
        let nightOnly = Set(Phrasebook.timeGreetings(for: .night).map {
            Phrasebook.render($0, name: "Sam")
        })

        var morningRepliesInPool = true
        var nightRepliesInPool = true
        var neverRepeats = true
        var previous: String?
        for _ in 0..<60 {
            let line = book.reply(to: .hello, name: "Sam", at: morning, calendar: calendar)
            if !morningPool.contains(line) { morningRepliesInPool = false }
            if line == previous { neverRepeats = false }
            previous = line
        }
        check(morningRepliesInPool, "a morning hello only ever says a morning line")
        check(neverRepeats, "and never says the same one twice running")

        previous = nil
        neverRepeats = true
        var sawEveryNightLine = Set<String>()
        var sawANightOnlyLine = false
        for _ in 0..<200 {
            let line = book.reply(to: .hello, name: "Sam", at: night, calendar: calendar)
            if !nightPool.contains(line) { nightRepliesInPool = false }
            if nightOnly.contains(line) { sawANightOnlyLine = true }
            if line == previous { neverRepeats = false }
            previous = line
            sawEveryNightLine.insert(line)
        }
        check(nightRepliesInPool, "a 1am hello only ever says a night line")
        check(neverRepeats, "and never says the same one twice running")
        check(sawANightOnlyLine, "and some of them are the lines only 1am gets")
        eq(sawEveryNightLine.count, nightPool.count, "every night line is reachable")

        // Crossing a boundary between two clicks is the case the no-repeat memory has to
        // survive: the pool it remembered a line from is not the pool it is drawing from
        // now, and the two overlap in the evergreen lines.
        var crossing = Phrasebook(seed: 5)
        var alternating: [String] = []
        for step in 0..<40 {
            alternating.append(crossing.reply(to: .hello, name: "Sam",
                                              at: step.isMultiple(of: 2) ? morning : night,
                                              calendar: calendar))
        }
        check(zip(alternating, alternating.dropFirst()).allSatisfy { $0 != $1 },
              "walking the clock past a boundary never repeats a line either")
        check(alternating.enumerated().allSatisfy { index, line in
                  index.isMultiple(of: 2) ? morningPool.contains(line) : nightPool.contains(line)
              },
              "and each reply belongs to the pool for the hour it was asked at")

        section("greetings: the clock changes nothing else")

        // The birthday swap in PetInteraction.say hands `reply` a `.birthday` prompt, not a
        // `.hello` one. If the clock reached any pool but hello's, the birthday greeting
        // would lose to the time of day on the one morning of the year it matters.
        check(Phrasebook.lines(for: .birthday, at: morning, calendar: calendar)
              == Phrasebook.lines(for: .birthday, at: night, calendar: calendar),
              "the birthday pool is the same at 8am and at 1am")
        check(Phrasebook.lines(for: .birthday, at: night, calendar: calendar)
              == Phrasebook.birthdayLines,
              "and it is still the pool the birthday feature reads")

        for prompt in PetPrompt.allCases where prompt != .hello {
            check(Phrasebook.lines(for: prompt, at: morning, calendar: calendar)
                  == Phrasebook.lines(for: prompt, at: night, calendar: calendar),
                  "\(prompt.rawValue) says the same things at any hour")
        }

        var birthdayBook = Phrasebook(seed: 8)
        let birthdayPool = Set(Phrasebook.birthdayLines.map {
            Phrasebook.render($0, name: "Sam")
        })
        check((0..<20).allSatisfy { _ in
                  birthdayPool.contains(birthdayBook.reply(to: .birthday, name: "Sam",
                                                           at: night, calendar: calendar))
              },
              "a birthday reply at 1am is still a birthday line")

        section("greetings: determinism")

        var first = Phrasebook(seed: 1234)
        var second = Phrasebook(seed: 1234)
        let dates = (0..<24).map { at($0) }
        let fromFirst = dates.map {
            first.reply(to: .hello, name: "Sam", at: $0, calendar: calendar)
        }
        let fromSecond = dates.map {
            second.reply(to: .hello, name: "Sam", at: $0, calendar: calendar)
        }
        check(fromFirst == fromSecond, "the same seed and the same clock produce the same words",
              detail: "\(fromFirst.prefix(2)) vs \(fromSecond.prefix(2))")

        var other = Phrasebook(seed: 4321)
        let fromOther = dates.map {
            other.reply(to: .hello, name: "Sam", at: $0, calendar: calendar)
        }
        check(fromFirst != fromOther, "a different seed produces different words")
    }
}
