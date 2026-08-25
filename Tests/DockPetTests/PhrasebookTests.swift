//
//  PhrasebookTests.swift: assertions for DockPetCore.Phrasebook (M10, click-to-interact)
//
//  The phrasebook is the only part of the interaction feature a user actually reads, so
//  the two things worth pinning down are: the name slot renders sensibly whether or not a
//  name exists, and the same seed always produces the same words.
//

import Foundation
import DockPetCore

enum PhrasebookTests {

    static func run() {

        section("phrasebook: the name slot")

        eq(Phrasebook.render("Hello, {name}!", name: "Tiago"), "Hello, Tiago!",
           "a name is substituted into the slot")

        eq(Phrasebook.render("Hello, {name}!", name: nil), "Hello!",
           "no name drops the slot and the comma that introduced it")

        eq(Phrasebook.render("Hello, {name}!", name: "   "), "Hello!",
           "a whitespace-only name counts as no name")

        eq(Phrasebook.render("{name}, you've got this.", name: nil), "You've got this.",
           "a slot at the start hands the sentence its capital letter back")

        eq(Phrasebook.render("{name}, you've got this.", name: "Tiago"), "Tiago, you've got this.",
           "and keeps the sentence as written when there is a name")

        eq(Phrasebook.render("Keep going, {name} (nearly there).", name: nil),
           "Keep going (nearly there).",
           "a slot in the middle leaves no double spacing behind")

        eq(Phrasebook.render("Nice to see you, {name}.", name: nil), "Nice to see you.",
           "a slot before a full stop does not strand the comma")

        eq(Phrasebook.render("Have a good one.", name: "Tiago"), "Have a good one.",
           "a template with no slot is returned unchanged")

        eq(Phrasebook.render("Hello, {name}!", name: "  Tiago  "), "Hello, Tiago!",
           "a name is trimmed before it is used")

        section("phrasebook: the pools")

        for prompt in PetPrompt.allCases {
            let lines = Phrasebook.lines(for: prompt)
            check(lines.count >= 2,
                  "\(prompt.rawValue) has at least two lines, so it can avoid repeating itself",
                  detail: "got \(lines.count)")
            check(lines.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                  "\(prompt.rawValue) has no blank lines")
            check(Set(lines).count == lines.count,
                  "\(prompt.rawValue) has no duplicate lines")
            check(!prompt.menuTitle.isEmpty, "\(prompt.rawValue) has a menu title")
        }

        check(PetPrompt.nap.forcedState == .sleep,
              "asking for a nap puts the pet to sleep")
        check(PetPrompt.hello.forcedState == nil,
              "a greeting does not change what the pet is doing")

        section("phrasebook: determinism")

        var a = Phrasebook(seed: 99)
        var b = Phrasebook(seed: 99)
        let fromA = (0..<12).map { _ in a.reply(to: .encourage, name: "Tiago") }
        let fromB = (0..<12).map { _ in b.reply(to: .encourage, name: "Tiago") }
        check(fromA == fromB, "the same seed produces the same words",
              detail: "\(fromA.prefix(2)) vs \(fromB.prefix(2))")

        var c = Phrasebook(seed: 7)
        let fromC = (0..<12).map { _ in c.reply(to: .encourage, name: "Tiago") }
        check(fromA != fromC, "a different seed produces different words")

        section("phrasebook: replies")

        var book = Phrasebook(seed: 4)
        for prompt in PetPrompt.allCases {
            let pool = Set(Phrasebook.lines(for: prompt).map {
                Phrasebook.render($0, name: "Tiago")
            })
            var previous: String?
            var allInPool = true
            var neverRepeats = true
            for _ in 0..<40 {
                let line = book.reply(to: prompt, name: "Tiago")
                if !pool.contains(line) { allInPool = false }
                if line == previous { neverRepeats = false }
                previous = line
            }
            check(allInPool, "\(prompt.rawValue) only ever says lines from its own pool")
            check(neverRepeats, "\(prompt.rawValue) never says the same line twice running")
        }

        // The no-repeat memory is per prompt: alternating prompts must not make one
        // prompt's last line block the other's.
        //
        // The draw count is a coupon-collector budget rather than a round number: covering
        // a pool of n lines takes about n·H(n) draws on average, so it has to grow with the
        // pool or this starts failing on the last line rather than on a real bug.
        var mixed = Phrasebook(seed: 11)
        var sawEveryHelloLine = Set<String>()
        for _ in 0..<400 {
            sawEveryHelloLine.insert(mixed.reply(to: .hello, name: nil))
            _ = mixed.reply(to: .fact, name: nil)
        }
        eq(sawEveryHelloLine.count, Phrasebook.lines(for: .hello).count,
           "every line in a pool is reachable")

        check(!book.reply(to: .hello, name: nil).contains("{name}"),
              "a reply never leaks the raw slot")
    }
}
