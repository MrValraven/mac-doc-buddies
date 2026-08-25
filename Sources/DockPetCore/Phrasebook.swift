//
//  Phrasebook.swift: what the pet says when you ask it something. Pure.
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
    /// also written so they read correctly with the name removed. See `render`.
    public static func lines(for prompt: PetPrompt) -> [String] {
        switch prompt {
        case .hello:
            return [
                "Hello, {name}!",
                "Oh, hi, {name}.",
                "There you are, {name}.",
                "I was hoping you'd click, {name}.",
                "Hey, {name}. Good to see you.",
                "{name}, hello. You're my favourite interruption.",
                "Hi, {name}. I saved you the warm end of the Dock.",
                "You're here. That's the good part of the day, {name}.",
                "Hello, {name}. I was just thinking about you.",
                "Oh good, it's you, {name}.",
                "Hi, {name}. Sit with me a minute?",
                "Hello, you. Hello, {name}.",
                "I like it when you click, {name}.",
                "Hi, {name}. The Dock is nicer with you looking at it.",
                "Hello, {name}. Stay a little?",
            ]
        case .encourage:
            return [
                "You've got this, {name}.",
                "{name}, you're doing better than you think.",
                "One thing at a time, {name}. That's all it ever is.",
                "Keep going, {name}. You're closer than it feels.",
                "Whatever it is, {name}, it's smaller than it looks from here.",
                "I believe in you, {name}. I'm a cat, but still.",
                "You're allowed a slow day, {name}. I have them constantly.",
                "Rest counts as progress, {name}. Ask any cat.",
                "I'd be proud of you either way, {name}.",
                "That's hard, and you're doing it anyway, {name}.",
                "Breathe, {name}. I'll wait right here.",
                "You've come further than the part you're stuck on.",
                "If it helps, {name}, I think you're wonderful.",
                "Nothing has to be finished today, {name}.",
                "You're not behind, {name}. You're in the middle, which is the hard bit.",
                "Come back to it later, {name}. It'll keep, and so will I.",
            ]
        case .fact:
            return [
                "Cats sleep about sixteen hours a day, {name}. I'm ahead of schedule.",
                "A group of cats is called a clowder.",
                "My whiskers are as wide as I am, so I always know what I fit through.",
                "Cats can't taste sweetness, {name}. We cope.",
                "A cat has thirty-two muscles in each ear. You have six.",
                "Nose prints work like fingerprints, {name}. No two are the same.",
                "A purr hums low enough to be good for bones, {name}. Possibly yours.",
                "Cats mostly meow for humans, {name}. Grown cats hardly bother with each other.",
                "Our collarbones float, attached to nothing, so we fit wherever we like.",
                "A slow blink is a cat saying it trusts you, {name}. Try one back at me.",
                "Kneading is the first happy thing a kitten learns, {name}. We never drop it.",
                "A cat can make around a hundred sounds, {name}. A dog manages ten.",
                "The little tufts inside our ears are called ear furnishings. Truly.",
                "We sweat through our paws, {name}. It is not a good system.",
                "A tail held straight up means a cat is glad you exist, {name}.",
                "Cats spend half their waking hours washing, {name}. It's very calming.",
            ]
        case .nap:
            return [
                "Good idea, {name}. Wake me for something important.",
                "Say no more.",
                "Napping. This is the job, {name}.",
                "Five minutes. Or forty.",
                "Only if you rest too, {name}.",
                "Come on then. I'll keep the warm spot for you.",
                "Curling up now, {name}. Think of me.",
                "Yes. Everything is kinder after a sleep.",
                "I'll be right here when you get back, {name}.",
                "Sleep is just tomorrow being nice to you early, {name}.",
                "Shh. Nap in progress.",
                "Wake me gently, {name}, or not at all.",
                "Off to dream about you, probably.",
                "Perfect. You can have the sunny half, {name}.",
            ]
        case .birthday:
            return [
                "Happy birthday, {name}!",
                "It's your day, {name}. I checked.",
                "Happy birthday, {name}. I got you a nap. It's for me.",
                "It's your birthday, {name}, so I'm walking extra today.",
                "Many happy returns, {name}. That's the formal one.",
                "Happy birthday, {name}. The whole Dock knows.",
                "Another year of you, {name}. Lucky us.",
                "I'd have baked, {name}, but no thumbs. Consider yourself purred at.",
                "Happy birthday, {name}. Be spoiled today, it's allowed.",
                "You were born, {name}, and that turned out lovely for me.",
                "Happy birthday, {name}. I'm doing my special walk.",
                "Make a wish, {name}. I'll hold still for it.",
                "One more trip around the sun, {name}, and you brought me along.",
                "Happy birthday to my favourite human, {name}.",
                "It's cake o'clock, {name}. I'm told cake is a big deal.",
            ]
        }
    }

    /// [M11] The birthday pool, reachable directly: on the day, it replaces the `hello`
    /// pool rather than sitting beside it as a prompt nobody would think to click.
    public static var birthdayLines: [String] { lines(for: .birthday) }

    /// Put `name` into a template, or take the slot out cleanly when there is no name.
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
        // name. Mid-sentence, as in "Whatever it is, {name}, it's fine", the second comma
        // is part of the sentence and has to stay.
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
    private var lastIndex: [PetPrompt: Int] = [:]

    public init(seed: UInt64) {
        self.rng = SplitMix64(seed: seed)
    }

    /// A line for `prompt`, never the one this prompt used last.
    public mutating func reply(to prompt: PetPrompt, name: String?) -> String {
        let pool = Self.lines(for: prompt)
        guard !pool.isEmpty else { return "" }

        var index = Int.random(in: 0..<pool.count, using: &rng)
        if pool.count > 1, index == lastIndex[prompt] {
            // Re-roll across the other lines only, so the replacement is drawn uniformly
            // rather than nudged onto whatever happens to sit next in the pool.
            let offset = Int.random(in: 0..<(pool.count - 1), using: &rng)
            index = (index + 1 + offset) % pool.count
        }
        lastIndex[prompt] = index
        return Self.render(pool[index], name: name)
    }
}

/// [M11] Half of a conversation and its answer.
///
/// A pair rather than two independent draws: a reply that does not answer the line is
/// worse than no reply. `{name}` in each half is the *other* cat's name, which is why the
/// M10 render rules apply unchanged: a cat with no name is exactly the "no name" case
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
    /// here would also break the promise `reply(to:)` keeps (never the same line twice
    /// running) for a moment that is meant to be the same every time.
    public static let kissLine = "Bisou, bisou!"

    /// What the pair says to each other once the hearts have faded.
    ///
    /// A `MeetingLine` rather than two strings because that is what it is: a line and the
    /// answer that only makes sense after it. Fixed for the same reason `kissLine` is:
    /// this is the one moment the app is not trying to be surprising. The extra "u" is not
    /// a typo.
    public static let loveLine = MeetingLine(opener: "I love you", reply: "And I love youu")

    public static let meetingPairs: [MeetingLine] = [
        MeetingLine(opener: "There you are, {name}.",
                    reply: "Here I am. Hello, {name}."),
        MeetingLine(opener: "I was hoping it would be you, {name}.",
                    reply: "I came the long way, just in case it was you."),
        MeetingLine(opener: "You're in my spot, {name}.",
                    reply: "Then we'll share the spot."),
        MeetingLine(opener: "Any plans today, {name}?",
                    reply: "Sitting near you, mostly."),
        MeetingLine(opener: "I walked all the way from the other end.",
                    reply: "I know, {name}. I watched the whole way."),
        MeetingLine(opener: "Did you know there are two of us now?",
                    reply: "I count us every morning, {name}."),
        MeetingLine(opener: "Race you back, {name}.",
                    reply: "Let's walk it instead, so it lasts longer."),
        MeetingLine(opener: "You smell like sunshine, {name}.",
                    reply: "I found a warm bit. You can have it."),
        MeetingLine(opener: "Shall we walk together, {name}?",
                    reply: "Slowly, though."),
        MeetingLine(opener: "I saved you half the sunny spot.",
                    reply: "You always do, {name}."),
        MeetingLine(opener: "What did you do all morning, {name}?",
                    reply: "Waited for this part."),
        MeetingLine(opener: "You've got a bit of fluff sticking up, {name}.",
                    reply: "Leave it. I like it there."),
        MeetingLine(opener: "Is it strange that I missed you, {name}?",
                    reply: "Not even slightly."),
        MeetingLine(opener: "Tell me something good, {name}.",
                    reply: "You're here. That's the something good."),
        MeetingLine(opener: "Sit closer, {name}. It's warmer.",
                    reply: "That's the only reason, obviously."),
        MeetingLine(opener: "I like the days you're on this end, {name}.",
                    reply: "Then I'll come this way more often."),
        MeetingLine(opener: "Same time tomorrow, {name}?",
                    reply: "Same time every day, if you like."),
    ]
}
