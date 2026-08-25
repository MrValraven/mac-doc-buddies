//
//  ReactionsTests.swift, [M13] the cat noticing which app came to the front.
//
//  The lines are the visible half of this feature and the rate limiting is the whole risk
//  of it, so those are the two things pinned here. A cat that comments on every alt-tab is
//  uninstalled on day two, which makes each limit below a correctness test rather than a
//  nicety. The section "a suppressed reaction costs nothing" is the one that keeps those
//  limits from being spent on lines nobody was ever shown.
//
//  SPEC §9: no clock is read anywhere in this file. Time passes because `elapse` says so.
//

import Foundation
import DockPetCore

enum ReactionsTests {

    // Four apps from the built-in table, because most of what is checked below is about
    // *sequences* of switches: a rule that only fires when a different app spoke in
    // between cannot be tested with one app, and re-activating the app already in front
    // is itself a case with its own answer.
    private static let safari = "com.apple.Safari"
    private static let figma = "com.figma.Desktop"
    private static let terminal = "com.apple.Terminal"
    private static let slack = "com.tinyspeck.slackmacgap"

    /// An app that will never be in the table, whatever ships in it.
    private static let unknown = "com.example.NobodysApp"

    /// Push `seconds` of elapsed time through the coordinator in steps it will accept.
    ///
    /// `advance` clamps a single call to `BehaviorMachine.maximumStep`, exactly as
    /// `MeetingCoordinator` and `Walker` do, so handing it one huge `dt` would not do what
    /// this reads as. Same reason `MeetingTests` walks its cooldown a second at a time
    /// rather than in one jump.
    private static func elapse(_ coordinator: inout ReactionCoordinator,
                               _ seconds: TimeInterval) {
        let step = BehaviorMachine.maximumStep
        var remaining = seconds
        while remaining > 0 {
            coordinator.advance(by: min(step, remaining))
            remaining -= step
        }
    }

    /// A coordinator with nothing standing in the way: no cooldown, global or per-app.
    private static func ready(seed: UInt64) -> ReactionCoordinator {
        var coordinator = ReactionCoordinator(seed: seed)
        elapse(&coordinator, ReactionCoordinator.perAppCooldown)
        return coordinator
    }

    /// The ordinary call: reactions switched on, and the cat free to speak.
    @discardableResult
    private static func react(_ coordinator: inout ReactionCoordinator,
                              _ bundleID: String?, name: String? = "Tiago") -> String? {
        coordinator.appActivated(bundleID, name: name,
                                 reactionsAllowed: true, canSpeak: true)
    }

    /// Move the frontmost app off whatever it was without spending anything.
    ///
    /// An app with no entry in the table is silent by design, so this is a real switch that
    /// cannot produce a line, which is exactly what the loops below need between two visits
    /// to the same app: re-activating the app already in front is not a switch at all.
    private static func switchAway(_ coordinator: inout ReactionCoordinator) {
        react(&coordinator, unknown)
    }

    static func run() {

        section("[M13] reactions: the built-in table")

        let table = Reactions.table
        check(table.count >= 16,
              "the table covers the obvious apps out of the box, with no config",
              detail: "got \(table.count)")

        for (bundleID, pool) in table {
            check(bundleID.contains("."),
                  "\(bundleID) is keyed on a bundle identifier, not a display name")
            check(pool.count >= 2,
                  "\(bundleID) has at least two lines, so it can avoid repeating itself",
                  detail: "got \(pool.count)")
            check(Set(pool).count == pool.count, "\(bundleID) has no duplicate lines")
            check(pool.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                  "\(bundleID) has no blank lines")
        }

        // A case-folded key collision would silently drop one app's whole pool, and that
        // app would then be as silent as one that had never been in the table at all.
        check(table.count == Set(table.keys.map { $0.lowercased() }).count,
              "no two table keys differ only by case")

        for bundleID in [safari, figma, terminal, slack] {
            check(Reactions.lines(for: bundleID) != nil,
                  "\(bundleID) is in the table, as the sequences below assume")
        }

        section("[M13] reactions: the M10 name-slot rule, on every line")

        for (bundleID, pool) in table {
            for line in pool {
                let withName = Phrasebook.render(line, name: "Tiago")
                let without = Phrasebook.render(line, name: nil)
                check(!withName.contains(Phrasebook.nameSlot),
                      "\(bundleID): the slot is filled: \(withName)")
                check(!without.contains(Phrasebook.nameSlot),
                      "\(bundleID): the slot is removed: \(without)")
                check(!without.hasPrefix(",") && !without.contains(" ,")
                      && !without.contains("  ") && !without.contains(" .")
                      && !without.contains(" ?") && !without.contains(" !"),
                      "\(bundleID): reads correctly with no name: \(without)")
                check(without.first?.isUppercase == true,
                      "\(bundleID): starts with a capital with no name: \(without)")
            }
        }

        section("[M13] reactions: lookup")

        check(Reactions.lines(for: "COM.APPLE.SAFARI") != nil,
              "lookup is case-insensitive: the real Mail is com.apple.mail while the real "
              + "Safari is com.apple.Safari, and a table typed in the wrong case would "
              + "silently match nothing")
        check(Reactions.lines(for: unknown) == nil,
              "an app with no entry has no pool: silence, not a generic line")

        section("[M13] reactions: an unknown app says nothing")

        do {
            var coordinator = ready(seed: 1)
            check(react(&coordinator, unknown) == nil,
                  "an app with no entry produces nothing at all")
            check(react(&coordinator, nil) == nil,
                  "an app with no bundle identifier produces nothing")
            // Neither of those can have spent the cooldown on its own silence.
            check(react(&coordinator, safari) != nil,
                  "a known app straight afterwards still speaks")
        }

        section("[M13] reactions: the hourly cooldown")

        do {
            var coordinator = ReactionCoordinator(seed: 2)
            check(react(&coordinator, safari) != nil,
                  "the first reaction of a session is not swallowed")
            check(react(&coordinator, figma) == nil,
                  "a second app inside the hour says nothing")

            elapse(&coordinator, ReactionCoordinator.cooldown - 60)
            check(react(&coordinator, terminal) == nil,
                  "a minute short of the hour, still nothing")

            elapse(&coordinator, 60)
            check(react(&coordinator, slack) != nil, "once the hour is up, she speaks again")
        }

        section("[M13] reactions: the per-app cooldown")

        do {
            var coordinator = ReactionCoordinator(seed: 3)
            check(react(&coordinator, figma) != nil, "Figma speaks")

            elapse(&coordinator, ReactionCoordinator.cooldown)
            check(react(&coordinator, safari) != nil, "an hour later, another app speaks")

            elapse(&coordinator, ReactionCoordinator.cooldown)
            check(react(&coordinator, figma) == nil,
                  "the global cooldown is up but Figma's own is not, so the same app is "
                  + "not the one that speaks twice running")

            elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            check(react(&coordinator, terminal) != nil, "a third app speaks in between")
            elapse(&coordinator, ReactionCoordinator.cooldown)
            check(react(&coordinator, figma) != nil,
                  "once the per-app cooldown is up, Figma can speak again")
        }

        section("[M13] reactions: coming straight back is one action, not two")

        do {
            var coordinator = ready(seed: 4)
            check(react(&coordinator, figma) != nil, "she comments on Figma")

            elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            check(react(&coordinator, safari) != nil, "and on Safari, an age later")

            elapse(&coordinator, 2)
            check(react(&coordinator, figma) == nil,
                  "coming back to Figma two seconds later is the same action, not a new one")

            // The window is about the switch away, not about Figma: stay gone long enough
            // and coming back is a fresh arrival.
            elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            check(react(&coordinator, safari) != nil, "Safari speaks again, much later")
            elapse(&coordinator, ReactionCoordinator.returnWindow + 1)
            elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            check(react(&coordinator, figma) != nil,
                  "and coming back well after the window is a fresh arrival")
        }

        do {
            var coordinator = ready(seed: 5)
            check(react(&coordinator, safari) != nil, "Safari speaks once")
            elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            check(react(&coordinator, safari) == nil,
                  "the app already in front activating again is not a switch at all")
        }

        section("[M13] reactions: a suppressed reaction costs nothing")

        do {
            // The cat is kissing, talking, being petted or asleep: `canSpeak` is false.
            var coordinator = ready(seed: 6)
            check(coordinator.appActivated(figma, name: "Tiago",
                                           reactionsAllowed: true, canSpeak: false) == nil,
                  "a busy cat does not interrupt herself with a remark about Figma")
            check(react(&coordinator, safari) != nil,
                  "the global cooldown was not spent: the very next switch still speaks")

            elapse(&coordinator, ReactionCoordinator.cooldown)
            check(react(&coordinator, figma) != nil,
                  "and Figma's per-app cooldown was not spent either, an hour after the "
                  + "reaction nobody saw and well short of the four-hour per-app cooldown")
        }

        do {
            // The config key is off.
            var coordinator = ready(seed: 7)
            check(coordinator.appActivated(figma, name: "Tiago",
                                           reactionsAllowed: false, canSpeak: true) == nil,
                  "reactions switched off produce nothing")
            check(react(&coordinator, safari) != nil,
                  "and switching them back on does not find the cooldown already spent")
            elapse(&coordinator, ReactionCoordinator.cooldown)
            check(react(&coordinator, figma) != nil,
                  "nor Figma's own, for the reaction it never gave")
        }

        section("[M13] reactions: the words")

        do {
            var coordinator = ready(seed: 9)
            guard let line = react(&coordinator, figma) else {
                Harness.bail("expected a line for Figma from a ready coordinator")
            }
            check(!line.isEmpty, "the line is not empty")
            check(!line.contains(Phrasebook.nameSlot), "the line never leaks the raw slot")

            var nameless = ready(seed: 9)
            guard let anonymous = react(&nameless, figma, name: nil) else {
                Harness.bail("expected a line for Figma with no name")
            }
            check(!anonymous.contains(Phrasebook.nameSlot),
                  "with no name the slot is removed, not left behind: \(anonymous)")
            check(!anonymous.contains("  ") && !anonymous.hasPrefix(","),
                  "and the line still reads correctly: \(anonymous)")
        }

        do {
            // Determinism, SPEC §9: the same seed says the same things.
            var a = ready(seed: 12)
            var b = ready(seed: 12)
            var fromA: [String] = []
            var fromB: [String] = []
            for _ in 0..<8 {
                if let line = react(&a, figma) { fromA.append(line) }
                if let line = react(&b, figma) { fromB.append(line) }
                switchAway(&a)
                switchAway(&b)
                elapse(&a, ReactionCoordinator.perAppCooldown)
                elapse(&b, ReactionCoordinator.perAppCooldown)
            }
            check(fromA.count == 8, "every one of the eight turns produced a line",
                  detail: "got \(fromA.count)")
            check(fromA == fromB, "the same seed produces the same words")
        }

        do {
            // Never the same line twice running, and every line reachable: the promise
            // `Phrasebook.reply` and `MeetingCoordinator.meet` both make.
            var coordinator = ready(seed: 13)
            let pool = Set(Reactions.lines(for: figma)!
                .map { Phrasebook.render($0, name: "Tiago") })
            var previous: String?
            var seen = Set<String>()
            var allInPool = true
            var neverRepeats = true
            for _ in 0..<60 {
                guard let line = react(&coordinator, figma) else {
                    Harness.bail("expected a line once both cooldowns had elapsed")
                }
                if !pool.contains(line) { allInPool = false }
                if line == previous { neverRepeats = false }
                previous = line
                seen.insert(line)
                switchAway(&coordinator)
                elapse(&coordinator, ReactionCoordinator.perAppCooldown)
            }
            check(allInPool, "an app only ever says lines from its own pool")
            check(neverRepeats, "and never the same line twice running")
            eq(seen.count, pool.count, "every line in the pool is reachable")
        }

        section("[M13] reactions: the clock")

        do {
            var coordinator = ReactionCoordinator(seed: 14)
            check(react(&coordinator, safari) != nil, "she speaks once")
            coordinator.advance(by: -5)
            coordinator.advance(by: 0)
            check(react(&coordinator, figma) == nil,
                  "time cannot run backwards into a reaction")

            // A stalled process hands back a huge elapsed time. Burning the whole cooldown
            // in one tick is exactly what the cooldown exists to prevent, so the step is
            // bounded here for the same reason `Walker` and `MeetingCoordinator` bound
            // theirs.
            coordinator.advance(by: ReactionCoordinator.cooldown * 10)
            check(react(&coordinator, terminal) == nil,
                  "one enormous tick does not buy an hour of cooldown")
        }
    }
}
