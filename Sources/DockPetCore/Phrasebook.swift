//
//  Phrasebook.swift — what the pet says when you ask it something. Pure.
//
//  SPEC §5: no AppKit here. The menu that shows these prompts and the bubble that draws
//  the reply are AppKit's problem; choosing the words is not, and keeping the choice in
//  DockPetCore is what makes it checkable without a screen (SPEC §9).
//

import Foundation

/// The things you can ask the pet for by clicking it.
public enum PetPrompt: String, CaseIterable {
    case hello, encourage, fact, nap, birthday

    /// The wording in the click menu.
    public var menuTitle: String {
        switch self {
        case .hello:     return "Say hello"
        case .encourage: return "Encourage me"
        case .fact:      return "Tell me a fact"
        case .nap:       return "Take a nap"
        case .birthday:  return "It's my birthday!"
        }
    }

    /// The state this prompt puts the pet into, if it changes what the pet is doing at all.
    ///
    /// Only the nap does. Everything else is talk: the pet says its line and goes back to
    /// whatever the behaviour machine had planned.
    public var forcedState: PetState? {
        switch self {
        case .nap: return .sleep
        default:   return nil
        }
    }
}

/// Picks the pet's words, without repeating itself.
///
/// Deterministic by construction. It takes a `SplitMix64` seed like `BehaviorMachine`
/// does, for the same reason: "it said something plausible when I clicked it" is not a
/// check (SPEC §9).
public struct Phrasebook {

    /// The slot a name drops into. Written once here so the pools and `render` cannot
    /// drift apart over a typo.
    public static let nameSlot = "{name}"

    /// Every line the pet knows.
    ///
    /// Each pool needs at least two entries, because `reply` promises never to repeat
    /// itself twice running and cannot keep that promise from a pool of one. The lines are
    /// also written so they read correctly with the name removed; see `render`.
    ///
    /// [M13] `date` and `calendar` exist for exactly one pool: `hello`, which is now the
    /// time-aware one. Both are defaulted, for two reasons. Every existing call site wants
    /// "now" and compiles untouched. And the only place `Date()` is read is this outermost
    /// boundary, rather than inside a function a test would then have to work around
    /// (SPEC §9).
    ///
    /// Every other pool ignores both and answers the same thing at any hour. That is what
    /// keeps the birthday swap in `PetInteraction.say` winning on the day: it hands `reply`
    /// a `.birthday` prompt, and the clock never reaches that pool.
    public static func lines(for prompt: PetPrompt,
                             at date: Date = Date(),
                             calendar: Calendar = .current) -> [String] {
        switch prompt {
        case .hello:
            // [M13] Routed rather than listed. The greetings and the reasoning about them
            // live together below; leaving a second, all-day list here as well is how the
            // two would drift apart, and only one of them would ever be said.
            return greetingLines(for: TimeOfDay.at(date, calendar: calendar))
        case .encourage:
            return [
                "You've got this, {name}.",
                "{name}, you're doing better than you think.",
                "One thing at a time, {name}. That's all it ever is.",
                "Keep going, {name} — you're closer than it feels.",
                "Whatever it is, {name}, it's smaller than it looks from here.",
                "I believe in you, {name}. I'm a cat, but still.",
            ]
        case .fact:
            return [
                "Cats sleep about sixteen hours a day, {name}. I'm ahead of schedule.",
                "A group of cats is called a clowder.",
                "My whiskers are as wide as I am — that's how I know what I fit through.",
                "Cats can't taste sweetness, {name}. We cope.",
                "A cat has thirty-two muscles in each ear. You have six.",
                "Nose prints work like fingerprints, {name}. No two are the same.",
            ]
        case .nap:
            return [
                "Good idea, {name}. Wake me for something important.",
                "Say no more.",
                "Napping. This is the job, {name}.",
                "Five minutes. Or forty.",
            ]
        case .birthday:
            return [
                "Happy birthday, {name}!",
                "{name}! It's your day. I checked.",
                "Happy birthday, {name}. I got you a nap. It's for me.",
                "It's your birthday, {name} — I'm walking extra today.",
                "Many happy returns, {name}. That's the formal one.",
            ]
        }
    }

    /// [M13] The greetings that fit at any hour: the original `hello` pool, unchanged.
    ///
    /// Kept, rather than replaced by the time-of-day pools, because they are still the
    /// right thing for a cat to say and because they are what the README quotes. They sit
    /// in every part of the day's pool, so the pet does not become a clock that only ever
    /// announces the hour back at you. The time-specific lines are the seasoning, not the
    /// meal.
    public static let anytimeGreetings: [String] = [
        "Hello, {name}!",
        "Oh, hi, {name}.",
        "There you are, {name}.",
        "{name}! I was hoping you'd click.",
        "Hey, {name}. Good to see you.",
    ]

    /// [M13] The greetings that only make sense at one part of the day.
    ///
    /// Four per part, deliberately few. These are the lines that carry the whole feature,
    /// so each one has to be worth reading a fifth time; a pool of twenty would be a pool
    /// of six good lines and fourteen that get skimmed. Four per part also keeps all four
    /// pools the same size, which matters more than it looks: `reply` draws an index, so
    /// equal-sized pools make its draw sequence identical whatever the hour, and a test of
    /// it cannot pass in the morning and fail at night.
    ///
    /// Every line obeys the M10 rule that `render` enforces: it must read correctly with
    /// `{name}` taken out, because being greeted without a name is a supported setting and
    /// not an error path. That is why none of them opens with the slot followed by its own
    /// punctuation.
    ///
    /// The night lines are the ones to be careful with. A cat that finds you up at 2am
    /// notices; it does not tell you to go to bed. The difference between "still up?" and
    /// "you should be asleep" is the difference between company and a smoke alarm.
    public static func timeGreetings(for time: TimeOfDay) -> [String] {
        switch time {
        case .morning:
            return [
                "Morning, {name}. The Dock's been quiet without you.",
                "Good morning, {name}. I've been up for hours. Sitting, mostly.",
                "You're up, {name}. That makes two of us.",
                "Morning, {name}. Coffee first. The rest can wait.",
            ]
        case .afternoon:
            return [
                "Afternoon, {name}. Halfway. That counts for something.",
                "Good afternoon, {name}. I've inspected the Dock. It's fine.",
                "Still going, {name}? So am I. Sort of.",
                "Afternoon, {name}. Stretch. It's the one thing I'm good at.",
            ]
        case .evening:
            return [
                "Evening, {name}. Whatever today was, it's over now.",
                "Good evening, {name}. You can put it down.",
                "You made it, {name}. Evenings are the better half.",
                "Evening, {name}. Is it dinner yet? Asking for me.",
            ]
        case .night:
            return [
                "Still up, {name}? Me too. Cats are night people.",
                "It's late, {name}. I'm not saying anything, I'm just here.",
                "Oh, you're still here, {name}. Good.",
                "Night shift, {name}? I'll keep you company.",
            ]
        }
    }

    /// [M13] Everything the pet may say as a greeting at `time`.
    ///
    /// The time-specific lines first and the evergreen ones after, though the order is
    /// cosmetic: `reply` draws uniformly across the whole pool, so the odds are four in
    /// nine that a greeting mentions the hour and five in nine that it does not. That ratio
    /// is the feature. Every greeting naming the time of day would wear out inside a week.
    public static func greetingLines(for time: TimeOfDay) -> [String] {
        timeGreetings(for: time) + anytimeGreetings
    }

    /// [M11] The birthday pool, reachable directly: on the day, it replaces the `hello`
    /// pool rather than sitting beside it as a prompt nobody would think to click.
    public static var birthdayLines: [String] { lines(for: .birthday) }

    /// Put `name` into a template — or take the slot out cleanly when there is no name.
    ///
    /// The awkward case is the second one. A template is written assuming a name, so
    /// deleting the slot naively leaves "Hello, !" or a doubled space. The rules:
    ///
    ///   * a comma that only existed to introduce the name goes with the name
    ///   * a slot at the start hands the next word its capital letter back
    ///   * whatever is left is joined without a doubled space
    ///
    /// A name that is missing, empty, or only whitespace is all the same case: no name.
    public static func render(_ template: String, name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let slot = template.range(of: nameSlot) else { return template }
        if !trimmed.isEmpty {
            return template.replacingOccurrences(of: nameSlot, with: trimmed)
        }

        var head = String(template[template.startIndex..<slot.lowerBound])
        var tail = String(template[slot.upperBound...])

        while head.last == " " { head.removeLast() }
        if head.hasSuffix(",") { head.removeLast() }

        // Only when the slot opened the sentence does the comma after it belong to the
        // name. Mid-sentence — "Whatever it is, {name}, it's fine" — the second comma is
        // part of the sentence and has to stay.
        if head.isEmpty {
            if tail.hasPrefix(",") { tail.removeFirst() }
            while tail.first == " " { tail.removeFirst() }
        }

        let joined = (head + tail).replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? capitalizingFirstLetter(joined) : joined
    }

    /// Uppercase the first character only. `capitalized` would lowercase the rest of the
    /// sentence and capitalise every word in it.
    private static func capitalizingFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    private var rng: SplitMix64

    /// The line each prompt used last, so the pet does not say the same thing twice in a
    /// row. Kept per prompt: asking for a fact must not constrain the next hello.
    ///
    /// [M13] The line itself, not its index. The index was enough while every pool was a
    /// fixed list, and it stopped being enough when `hello` started depending on the clock:
    /// a pet left running past 22:00 would compare "index 3 of this evening's greetings"
    /// against "index 3 of tonight's", which is a different sentence, and so would both
    /// block a line it never said and allow the one it just did. Storing the template makes
    /// the comparison mean what it says. For a pool that has not changed, the draw sequence
    /// is identical to the index version's, so nothing else moves.
    private var lastLine: [PetPrompt: String] = [:]

    public init(seed: UInt64) {
        self.rng = SplitMix64(seed: seed)
    }

    /// A line for `prompt`, never the one this prompt used last.
    ///
    /// [M13] `at` and `calendar` are passed straight through to `lines(for:at:calendar:)`,
    /// where only the `hello` pool reads them, and are defaulted here for the same reason
    /// they are defaulted there: `PetInteraction` asks the question at the moment of the
    /// click and means "now", while a test says which hour it is asking about (SPEC §9).
    public mutating func reply(to prompt: PetPrompt, name: String?,
                               at date: Date = Date(),
                               calendar: Calendar = .current) -> String {
        let pool = Self.lines(for: prompt, at: date, calendar: calendar)
        guard !pool.isEmpty else { return "" }

        var index = Int.random(in: 0..<pool.count, using: &rng)
        if pool.count > 1, pool[index] == lastLine[prompt] {
            // Re-roll across the other lines only, so the replacement is drawn uniformly
            // rather than nudged onto whatever happens to sit next in the pool.
            let offset = Int.random(in: 0..<(pool.count - 1), using: &rng)
            index = (index + 1 + offset) % pool.count
        }
        lastLine[prompt] = pool[index]
        return Self.render(pool[index], name: name)
    }
}

/// [M11] Half of a conversation and its answer.
///
/// A pair rather than two independent draws: a reply that does not answer the line is
/// worse than no reply. `{name}` in each half is the *other* cat's name, which is why the
/// M10 render rules apply unchanged — a cat with no name is exactly the "no name" case
/// those rules already handle.
public struct MeetingLine: Equatable {
    public let opener: String
    public let reply: String

    public init(opener: String, reply: String) {
        self.opener = opener
        self.reply = reply
    }
}

extension Phrasebook {

    /// [M12] What a cat says on reaching the one it crossed the Dock for.
    ///
    /// One line rather than a pool, and no `{name}` in it: the kiss has an announcement,
    /// not a conversation, and the cat it is addressed to is standing against it. A pool
    /// here would also break the promise `reply(to:)` keeps — never the same line twice
    /// running — for a moment that is meant to be the same every time.
    public static let kissLine = "Bisou, bisou!"

    /// What the pair says to each other once the hearts have faded.
    ///
    /// A `MeetingLine` rather than two strings because that is what it is: a line and the
    /// answer that only makes sense after it. Fixed for the same reason `kissLine` is —
    /// this is the one moment the app is not trying to be surprising. The extra "u" is not
    /// a typo.
    public static let loveLine = MeetingLine(opener: "I love you", reply: "And I love youu")

    public static let meetingPairs: [MeetingLine] = [
        MeetingLine(opener: "Oh — hello, {name}.",
                    reply: "Hello yourself, {name}."),
        MeetingLine(opener: "Fancy meeting you here, {name}.",
                    reply: "It's a narrow Dock. It was always going to happen."),
        MeetingLine(opener: "You're in my spot, {name}.",
                    reply: "It's a very good spot."),
        MeetingLine(opener: "Any plans today, {name}?",
                    reply: "Sitting. Possibly some lying down."),
        MeetingLine(opener: "I walked all the way from the other end.",
                    reply: "I know, {name}. I watched."),
        MeetingLine(opener: "Did you know there are two of us now?",
                    reply: "I had noticed, {name}."),
        MeetingLine(opener: "Race you back, {name}.",
                    reply: "No."),
    ]
}
