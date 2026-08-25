//
//  Reactions.swift, [M13] the cat notices which app you just brought to the front.
//
//  SPEC §5: no AppKit here. Watching for the frontmost application is AppKit's problem
//  (`AppWatcher`); deciding whether the cat says anything about it, and what, is not. All
//  of that lives here so it can be checked without a screen and without waiting an hour
//  for a cooldown (SPEC §9).
//
//  SPEC §6: this file adds no timer. It is advanced from the poll the app already runs,
//  and it only ever decides anything when the system tells the app that the frontmost
//  application changed.
//

import CoreGraphics
import Foundation

/// What the cat knows how to say about the app you just switched to.
///
/// Built in rather than configured, and that was a deliberate decision rather than a first
/// draft: a table in `config.json` would mean the feature does nothing at all until
/// somebody sits down and writes lines for it, and this is an app given as a gift. Shipping
/// a pool for the obvious apps is what makes it work on the first launch on somebody else's
/// Mac, with no file to edit.
public enum Reactions {

    /// App to lines, keyed on **bundle identifier**.
    ///
    /// Not on the display name, and this is the whole reason the table looks like this.
    /// Display names are localised: on a French macOS the Mail app is "Mail" but Calendar
    /// is "Calendrier" and System Settings is "Réglages", and a table keyed on names would
    /// silently match nothing on exactly the machine this app is a gift for. A bundle
    /// identifier is the same string in every language and every release.
    ///
    /// The identifiers are written here with their real capitalisation, which is not
    /// uniform (`com.apple.mail` is lower case, `com.apple.Safari` is not, and Calendar is
    /// still `com.apple.iCal` from the days when it was iCal). Lookup folds case, so a
    /// typo in the casing costs nothing; see `lines(for:)`.
    ///
    /// Every line obeys the M10 name-slot rule: it must read correctly with `{name}`
    /// removed, because the user may not have told the app their name, and
    /// `Phrasebook.render` is the only thing allowed to take the slot out. Each pool holds
    /// at least two lines, because `appActivated` promises never to repeat itself twice
    /// running and cannot keep that promise from a pool of one. The same rules the
    /// phrasebook pools live under, tested the same way.
    public static let table: [String: [String]] = [

        "com.spotify.client": [
            "Music. Good call, {name}.",
            "Put something with a beat on, {name}.",
            "Is this the same playlist as yesterday, {name}?",
        ],

        "com.apple.Music": [
            "Ah, the good speakers.",
            "Play the one with the cat in it, {name}.",
            "{name}, I have notes on your taste.",
        ],

        "com.apple.Safari": [
            "Off we go, {name}. Try to come back.",
            "Just the one tab, {name}? I don't believe you.",
            "The internet again. It's still all there.",
        ],

        "com.google.Chrome": [
            "All of the tabs, {name}. Every one of them.",
            "The fans are at ninety percent, {name}. Just so you know.",
            "Chrome. Bold, on this battery.",
        ],

        "com.figma.Desktop": [
            "Figma again, {name}?",
            "Nudge it one pixel left, {name}. Trust me.",
            "{name}, it was fine three versions ago.",
        ],

        "com.apple.mail": [
            "Brave of you, {name}.",
            "The inbox. I'll be over here, {name}.",
            "{name}, you don't have to answer all of them today.",
        ],

        "com.tinyspeck.slackmacgap": [
            "Someone needs you, {name}. Allegedly.",
            "{name}, you could read it in an hour instead.",
            "Little red dots. Ignore them.",
        ],

        "com.apple.MobileSMS": [
            "Say hello from me, {name}.",
            "{name}, tell them the cat is doing well.",
            "Who is it? Are they nice?",
        ],

        "com.apple.Notes": [
            "Write it down before it's gone, {name}.",
            "{name}, this is where the good ideas go quiet.",
            "Another list. I approve.",
        ],

        "com.apple.iCal": [
            "Checking what's coming, {name}? Be brave.",
            "{name}, you could still cancel one of those.",
            "Nothing until eleven. That's a nap.",
        ],

        "com.apple.Photos": [
            "Any of me, {name}?",
            "{name}, that one's blurry. Keep it anyway.",
            "Scrolling backwards. I'll allow it.",
        ],

        "com.apple.dt.Xcode": [
            "Good luck, {name}.",
            "{name}, it built yesterday. That still counts.",
            "I'll be here when it finishes indexing.",
        ],

        "com.microsoft.VSCode": [
            "Back to the code, {name}.",
            "{name}, save it before you rename anything.",
            "Someone's been busy. All these little files.",
        ],

        "com.apple.Terminal": [
            "Careful in there, {name}.",
            "{name}, read the command twice.",
            "A black rectangle. My favourite kind of app.",
        ],

        "us.zoom.xos": [
            "Camera up, {name}. Sit up straight.",
            "{name}, I'm staying out of frame.",
            "Say it's been a busy week. It has.",
        ],

        "com.netflix.Netflix": [
            "Finally, {name}.",
            "{name}, one episode. That was the deal.",
            "Move over. I sit on the left.",
        ],
    ]

    /// `table` folded to lower case once, so every lookup is not folding sixteen keys.
    ///
    /// Duplicates are resolved by keeping the first rather than by `uniqueKeysWithValues`,
    /// which traps: two keys differing only in case are a typo in the table above, and
    /// crashing the app on launch is a far worse answer to a typo than one app being
    /// slightly less talkative. `ReactionsTests` fails on that collision instead, which is
    /// where a typo should be caught.
    private static let index: [String: [String]] =
        Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })

    /// The lines for an app, or `nil` if the cat has nothing to say about it.
    ///
    /// `nil` rather than an empty array, and never a generic fallback line: an app with no
    /// entry is the overwhelmingly common case (there are hundreds of apps and sixteen
    /// entries), and "Ooh, an app!" every time you open something unusual is the version of
    /// this feature that gets the app closed. Silence is the correct answer.
    ///
    /// Case-folded because bundle identifiers are compared case-insensitively in practice
    /// and are not written consistently by their vendors.
    public static func lines(for bundleID: String) -> [String]? {
        index[bundleID.lowercased()]
    }
}

/// Decides whether the cat remarks on the app that just came to the front, and which line
/// she uses.
///
/// The sibling of `MeetingCoordinator`, and built the same way for the same reasons: a
/// seeded RNG, a cooldown, a no-repeat rule, and elapsed time taken as a parameter rather
/// than read from a clock (SPEC §9). "She seemed to comment about the right amount" is not
/// a check, and a cooldown of an hour cannot be tested at all by a test that waits.
///
/// **The rate limiting is the feature.** Everything else here is a table lookup. A cat that
/// says something every time you alt-tab is charming for about four minutes and then it is
/// an app you uninstall, so there are three separate limits, and each one exists because it
/// covers a case the others do not:
///
///   * `cooldown`, about an hour, between reactions of any kind. This is what makes her
///     *occasional*.
///   * `perAppCooldown`, four hours, so the same app is never the one that speaks twice
///     running. Without it, somebody who lives in two apps would hear about the same one
///     all day, and the pool would feel much smaller than it is.
///   * `returnWindow`, a few seconds, so glancing at another window and coming straight
///     back is read as one action rather than two.
///
/// A rejected alternative: rolling a die per switch, the way `MeetingCoordinator` rolls for
/// a kiss. It was the first design and it is worse here. A probability alone gives no upper
/// bound on how often she speaks (an unlucky run of switches is a run of remarks), while a
/// probability *plus* the cooldown makes the feature so rare that a user could go days
/// without seeing it and reasonably conclude it does not work. The cooldown alone is both
/// bounded above and reliably visible.
public struct ReactionCoordinator {

    /// Between reactions of any kind, whatever the app.
    public static let cooldown: TimeInterval = 60 * 60

    /// Before the same app may be remarked on again.
    ///
    /// Deliberately several times the global cooldown: within one working day that caps an
    /// app at two remarks, so the four apps somebody actually uses cannot crowd out the
    /// rest of the table.
    public static let perAppCooldown: TimeInterval = 4 * 60 * 60

    /// Switching away and back inside this window is one action, not two.
    ///
    /// Sized for the real gesture it exists to swallow: flipping to a browser to check one
    /// thing, or a chat window that steals focus and is dismissed. Longer, and a genuine
    /// "put that away, back to work" switch stops being noticed at all; shorter, and the
    /// bounce gets through.
    public static let returnWindow: TimeInterval = 6

    /// The only clock this type has: seconds, counted from the first `advance`.
    ///
    /// A monotonic accumulator with stamps taken off it, rather than a set of countdowns
    /// each ticked separately. Two cooldowns and a return window ticking independently is
    /// three places to forget to reset, and the per-app one is a dictionary that would have
    /// to be walked on every tick.
    private var clock: TimeInterval = 0

    /// When she last said anything, or `nil` if she has not yet this session.
    ///
    /// `nil` rather than a clock started at `cooldown`: the first switch after launch
    /// should be able to produce a remark. A cat that ignores the first hour of the session
    /// looks broken in exactly the way `MeetingCoordinator` avoids by starting its own
    /// cooldown already elapsed.
    private var lastReactionAt: TimeInterval?

    /// When each app was last remarked on. Only apps that actually spoke are ever recorded,
    /// so this is bounded by the size of the table rather than by how many apps are running.
    private var lastReactionAtForApp: [String: TimeInterval] = [:]

    /// The line each app used last, so she does not say the same thing about the same app
    /// twice running. Per app, for the reason `Phrasebook` keeps it per prompt.
    private var lastLineIndex: [String: Int] = [:]

    /// The app in front, the one before it, and when that switch happened. Together these
    /// are what makes "you came straight back" answerable without a history buffer.
    private var frontApp: String?
    private var previousApp: String?
    private var frontAppSince: TimeInterval = 0

    private var rng: SplitMix64

    public init(seed: UInt64) {
        self.rng = SplitMix64(seed: seed)
    }

    /// Let `dt` seconds pass.
    ///
    /// Bounded for the same reason `Walker`, `BehaviorMachine` and `MeetingCoordinator`
    /// bound theirs: a stalled process, or a Mac coming back from sleep, hands back an
    /// enormous elapsed time, and letting one tick pay off an hour of cooldown is exactly
    /// what the cooldown exists to prevent. The bound is `BehaviorMachine.maximumStep`
    /// (one second) rather than `Walker`'s quarter second because this is driven from the
    /// app's 500 ms poll, and a bound below the interval that feeds it would run this
    /// clock permanently slow.
    ///
    /// The consequence, stated so it is not mistaken for a bug later: the hour is an hour
    /// of *the app polling*, not an hour of wall clock. While the pet is paused or dormant
    /// the poll stops advancing this, so the cooldown stretches. That is the right way
    /// round. Time when there was no cat on screen is not time the user spent listening
    /// to her.
    public mutating func advance(by dt: TimeInterval) {
        guard dt > 0 else { return }
        clock += min(dt, BehaviorMachine.maximumStep)
    }

    /// An app came to the front. Returns the line to say, or `nil` for silence.
    ///
    /// A non-`nil` return means the reaction **was delivered**: the cooldowns are spent on
    /// the way out of this method, so a caller that takes a line and then decides not to
    /// show it has burned an hour of the feature on a bubble nobody saw. That is why the
    /// two ways of saying "not now" are parameters rather than something the caller does
    /// with the result:
    ///
    ///   * `reactionsAllowed` is the config key, passed in and never read from a global,
    ///     for the reason `MeetingCoordinator.meet` takes `kissesAllowed`: this type knows
    ///     nothing about where settings live, and a coordinator that consulted one could
    ///     not be run twice in a test with the answer switched both ways.
    ///   * `canSpeak` is the app saying the cat is busy. A cat that is kissing, already
    ///     talking, being petted or asleep does not interrupt any of that with a remark
    ///     about Safari: this feature is the one that must lose. Suppression here costs
    ///     nothing at all, so the next switch is judged exactly as if this one had never
    ///     been offered.
    ///
    /// The switch itself is recorded either way. What the *user* did is not conditional on
    /// whether the cat was free to comment on it, and the return-window rule below would be
    /// wrong for the rest of the session if a suppressed switch left no trace.
    public mutating func appActivated(_ bundleID: String?, name: String?,
                                      reactionsAllowed: Bool, canSpeak: Bool) -> String? {
        let key = bundleID?.lowercased()

        // Both questions are about the state this switch is about to overwrite, so they are
        // asked before it is recorded.
        //
        // `isAlreadyInFront` is the same app announcing itself twice with nothing in
        // between. That is not a switch: the user did nothing, so there is nothing to
        // notice. `hasComeStraightBack` is the bounce, A to B to A within the window.
        let isAlreadyInFront = key != nil && key == frontApp
        let hasComeStraightBack = key != nil && key == previousApp
            && clock - frontAppSince < Self.returnWindow

        noteSwitch(to: key)

        guard reactionsAllowed, canSpeak, !isAlreadyInFront, !hasComeStraightBack,
              let key, let pool = Reactions.lines(for: key), !pool.isEmpty else { return nil }

        if let last = lastReactionAt, clock - last < Self.cooldown { return nil }
        if let last = lastReactionAtForApp[key], clock - last < Self.perAppCooldown { return nil }

        var line = Int.random(in: 0..<pool.count, using: &rng)
        if pool.count > 1, line == lastLineIndex[key] {
            // Re-roll across the others only, so the replacement is drawn uniformly rather
            // than nudged onto whatever sits next in the pool. Same rule, and the same
            // reason for it, as `Phrasebook.reply` and `MeetingCoordinator.meet`.
            let offset = Int.random(in: 0..<(pool.count - 1), using: &rng)
            line = (line + 1 + offset) % pool.count
        }

        lastLineIndex[key] = line
        lastReactionAt = clock
        lastReactionAtForApp[key] = clock

        return Phrasebook.render(pool[line], name: name)
    }

    /// Remember that the front app changed, and when.
    ///
    /// A re-announcement of the app already in front deliberately changes nothing, not even
    /// `frontAppSince`: if it did, an app that re-posts its activation every few seconds
    /// would keep pushing the window forward and could hold a genuine return suppressed
    /// indefinitely.
    private mutating func noteSwitch(to key: String?) {
        guard key != frontApp else { return }
        previousApp = frontApp
        frontApp = key
        frontAppSince = clock
    }
}
