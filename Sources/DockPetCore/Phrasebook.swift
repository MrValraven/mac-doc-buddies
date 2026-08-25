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
    case hello, encourage, fact, nap

    /// The wording in the click menu.
    public var menuTitle: String {
        switch self {
        case .hello:     return "Say hello"
        case .encourage: return "Encourage me"
        case .fact:      return "Tell me a fact"
        case .nap:       return "Take a nap"
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
/// Deterministic by construction — it takes a `SplitMix64` seed like `BehaviorMachine`
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
    /// also written so they read correctly with the name removed — see `render`.
    public static func lines(for prompt: PetPrompt) -> [String] {
        switch prompt {
        case .hello:
            return [
                "Hello, {name}!",
                "Oh — hi, {name}.",
                "There you are, {name}.",
                "{name}! I was hoping you'd click.",
                "Hey, {name}. Good to see you.",
            ]
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
        }
    }

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
