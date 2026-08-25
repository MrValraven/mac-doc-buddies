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

/// Decides when two pets have met, and what they say.
///
/// SPEC §9: deterministic by construction, and it takes elapsed time as a parameter rather
/// than reading a clock — "they seemed to talk about the right amount" is not a check.
public struct MeetingCoordinator {

    /// A pair of cats that chat every fifteen seconds is noise by the second hour.
    public static let cooldown: TimeInterval = 60

    /// How long the opener stays up before the reply. Long enough to be read as an
    /// exchange rather than as two cats talking over each other.
    public static let replyDelay: TimeInterval = 1.5

    public struct Exchange: Equatable {
        public let opener: String
        public let reply: String
    }

    /// [M12] What a meeting turned out to be.
    ///
    /// One type rather than two methods, because a meeting is one or the other and the
    /// cooldown is spent either way. Two entry points that both stamped the cooldown would
    /// be two doors into the same room, and the second one to be written would eventually
    /// forget to close it.
    public enum Encounter: Equatable {
        /// A line and its answer, as every meeting was before M12.
        case chat(Exchange)
        /// The pair walks together, announces itself with this line, and kisses.
        case kiss(String)
        /// [M14] The pair walks together and sleeps against each other for a while.
        ///
        /// No payload, where the kiss carries its announcement: a nap says three things
        /// rather than one, and the routine picks them as it reaches each phase. Handing
        /// them all over here would mean choosing the waking line twenty seconds before
        /// anybody wakes up.
        case cuddle

        /// The words traded, or `nil` for a kiss. Lets a caller that only cares about
        /// speech stay written the way it was.
        public var exchange: Exchange? {
            if case .chat(let exchange) = self { return exchange }
            return nil
        }

        public var isKiss: Bool {
            if case .kiss = self { return true }
            return false
        }

        /// [M14]
        public var isCuddle: Bool {
            if case .cuddle = self { return true }
            return false
        }
    }

    /// [M12] How often a meeting becomes a kiss, when kissing is switched on.
    ///
    /// One in five: often enough to be seen in an afternoon, rare enough that the pair
    /// still has an ordinary relationship the rest of the time. The cooldown does the real
    /// rate limiting — at 60 s between meetings this is a kiss every few minutes at most.
    public static let kissChance = 0.2

    /// [M14] How often a meeting becomes a nap instead, when napping is switched on.
    ///
    /// Lower than the kiss, and deliberately: a nap holds both cats for twenty seconds
    /// where a kiss holds them for six, so the same rate would take three times as much of
    /// the pair's day. Rolled after the kiss, so with both switched on it is a nap about
    /// one meeting in eight, which at a 60 s cooldown is a couple an hour at most.
    public static let cuddleChance = 0.15

    /// Starts at the cooldown so the first meeting of a session is not swallowed. A pair
    /// of cats that ignore each other for the first minute after launch looks broken.
    private var sinceLastMeeting: TimeInterval = MeetingCoordinator.cooldown
    private var rng: SplitMix64
    private var lastPairIndex: Int?

    public init(seed: UInt64) {
        self.rng = SplitMix64(seed: seed)
    }

    /// Two pets have met when their windows overlap on the strip.
    ///
    /// Frame overlap rather than a distance threshold, because the frames are what the
    /// user sees: two cats whose art is touching have visibly met, whatever their centres
    /// are doing.
    public static func haveMet(_ a: CGRect, _ b: CGRect) -> Bool {
        a.intersects(b) || a == b
    }

    public mutating func advance(by dt: TimeInterval) {
        guard dt > 0 else { return }
        // Bounded for the same reason `Walker` and `BehaviorMachine` bound theirs: a
        // stalled process hands back a huge elapsed time, and burning the whole cooldown
        // in one tick is exactly what the cooldown exists to prevent.
        sinceLastMeeting += min(dt, BehaviorMachine.maximumStep)
    }

    /// [M12] Spend the cooldown without holding a meeting.
    ///
    /// For the kiss asked for from the click menu: it never goes through `meet`, but the
    /// pair has just spent six seconds nose to nose, and two cats who strike up a
    /// conversation the instant they stop kissing look like two features fighting over the
    /// same pair rather than one pair of cats.
    public mutating func noteMeeting() {
        sinceLastMeeting = 0
    }

    /// An encounter if these two have just met and the cooldown has elapsed, else `nil`.
    ///
    /// `openerName` is the cat that speaks first, `replierName` the one that answers —
    /// and each line addresses the *other* one, so the opener renders with `replierName`.
    ///
    /// [M12] `kissesAllowed` is the config toggle, passed in rather than read: this type
    /// knows nothing about where settings live, and a coordinator that consulted a global
    /// could not be run four hundred times in a test with the answer switched both ways.
    /// It defaults to off so that a caller which has not thought about kissing gets the
    /// M11 behaviour rather than a surprise.
    ///
    /// [M14] `cuddlesAllowed` is the second toggle, and is rolled after the kiss for the
    /// same reason the kiss is rolled only when it is on: a switched-off feature must draw
    /// no random numbers at all, or turning it on would silently rewrite which
    /// conversations every seed produces.
    public mutating func meet(_ a: CGRect, _ b: CGRect,
                              openerName: String?, replierName: String?,
                              kissesAllowed: Bool = false,
                              cuddlesAllowed: Bool = false) -> Encounter? {
        guard Self.haveMet(a, b), sinceLastMeeting >= Self.cooldown else { return nil }
        sinceLastMeeting = 0

        // Rolled before the line is picked, and only when kissing is on, so switching the
        // toggle does not shift which conversations a given seed produces.
        if kissesAllowed, Double.random(in: 0..<1, using: &rng) < Self.kissChance {
            return .kiss(Phrasebook.kissLine)
        }

        if cuddlesAllowed, Double.random(in: 0..<1, using: &rng) < Self.cuddleChance {
            return .cuddle
        }

        let pairs = Phrasebook.meetingPairs
        guard !pairs.isEmpty else { return nil }

        var index = Int.random(in: 0..<pairs.count, using: &rng)
        if pairs.count > 1, index == lastPairIndex {
            // Re-roll across the others only, so the replacement is drawn uniformly rather
            // than nudged onto whatever sits next in the pool — same rule as `Phrasebook`.
            let offset = Int.random(in: 0..<(pairs.count - 1), using: &rng)
            index = (index + 1 + offset) % pairs.count
        }
        lastPairIndex = index

        return .chat(Exchange(opener: Phrasebook.render(pairs[index].opener, name: replierName),
                              reply: Phrasebook.render(pairs[index].reply, name: openerName)))
    }
}
