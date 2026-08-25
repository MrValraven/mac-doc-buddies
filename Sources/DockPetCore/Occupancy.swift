//
//  Occupancy.swift: [M13] what owns a cat right now, and who is allowed to take it.
//
//  SPEC §5: no AppKit. Deciding whether the cursor may have a cat is a rule, not a
//  drawing, and rules that live in AppDelegate cannot be checked without a screen (§9).
//
//  ## Why this exists
//
//  Through M12 there was exactly one thing that could take a cat away from its behaviour
//  machine (the kiss), and one guard expressed it: `guard kiss == nil`. M13 adds four
//  more claimants (the cursor, a Dock tile to sleep on, a remark about an app, and the
//  birthday scene) and each of them can want the same cat at the same moment.
//
//  Written as guards, that is a quadratic pile of `kiss == nil && !isTalking && ...` in
//  five call sites, each of which has to be updated when the sixth claimant arrives, and
//  every one of which fails *silently* when it is wrong: a feature that loses a contest it
//  should have won is indistinguishable from a feature that is simply not very active. So
//  the contests are decided in one place, by a table, and the table is tested.
//
//  This type holds no cats and knows nothing about windows. It is a bookkeeper: it answers
//  "may I", records "I have it", and hands it back.
//

import Foundation

/// The things that can take a cat away from its behaviour machine, in priority order.
///
/// The order **is** the design, and it reads bottom-up as "how much has the user got to do
/// with this":
///
///   * `napSpot` is the cat amusing itself. Anything may interrupt it.
///   * `reacting` is the cat volunteering a remark. It waits its turn behind everything the
///     user actually asked for.
///   * `meeting` is the two cats' own business, and it sits *below* `talking` and `petted`
///     because a human reaching for a cat outranks the cat's conversation, and because
///     that is already what the app does: `considerMeeting` refuses to start while either
///     cat is talking, and a click mid-meeting takes the cat.
///   * `talking` and `petted` are the user, directly. Nothing autonomous interrupts them.
///   * `kiss` and `scene` are scripted sequences that run to completion. They outrank
///     everything because being cut off half way leaves a cat stranded mid-walk with
///     hearts over its head and no code path left to take them down.
///
/// `scene` is the top because it happens once a year and nothing on this list is worth
/// spoiling it for.
public enum PetActivity: Int, Comparable, CaseIterable, Equatable {
    case napSpot
    case reacting
    case meeting
    case talking
    case petted
    case kiss
    case scene

    public static func < (lhs: PetActivity, rhs: PetActivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Who currently holds each cat.
///
/// Indices are positions in `AppDelegate`'s `pets` array, so this type never retains a
/// `Pet` and cannot keep one alive past a cast rebuild. `reset(petCount:)` is how it is
/// told the cast changed.
public struct PetOccupancy: Equatable {

    /// One slot per cat. `nil` means the behaviour machine is driving, which is the
    /// ordinary case and the reason the array is of optionals rather than of a `.idle`
    /// case: "nobody has claimed this" is the absence of a claimant, and giving it a
    /// `PetActivity` spelling would put it in the priority ordering, where it would have
    /// to be remembered as the one member that must never be claimed.
    private var holders: [PetActivity?]

    public init(petCount: Int) {
        holders = Array(repeating: nil, count: max(0, petCount))
    }

    /// What owns this cat, or `nil` for nobody, including for an index past the cast.
    ///
    /// An out-of-range index answers rather than traps. The app has been wrong about its
    /// own indices before (a cast rebuilt mid-kiss is exactly that bug), and the cost of
    /// being wrong here should be a cat that does not get petted, not a crash on her Dock.
    public func activity(of pet: Int) -> PetActivity? {
        guard holders.indices.contains(pet) else { return nil }
        return holders[pet]
    }

    /// Could `activity` take this cat right now?
    ///
    /// Strictly outranking, not merely matching: an activity may not claim a cat it
    /// already holds. Re-claiming would restart a sequence that is already running: the
    /// cursor crossing a watching cat would reset its watch every mouse-move event, and
    /// "I am already doing this" is not a reason to begin again.
    public func isAvailable(_ pet: Int, for activity: PetActivity) -> Bool {
        guard holders.indices.contains(pet) else { return false }
        guard let holder = holders[pet] else { return true }
        return activity > holder
    }

    /// Take one or more cats for `activity`, or take none of them.
    ///
    /// **All or nothing, and that is the point of passing an array.** A kiss, a meeting and
    /// the birthday scene each need both cats: granted one and refused the other, the
    /// caller would walk one cat to the middle of the Dock to be kissed by a cat that is
    /// asleep at the far end, and there is no code path that recovers from it. Refusing
    /// the whole claim leaves the caller to try again a tick later, which is free.
    ///
    /// Returns whether the claim was granted.
    @discardableResult
    public mutating func claim(_ activity: PetActivity, pets: [Int]) -> Bool {
        // An empty claim is a caller bug, most likely a filtered array that came back
        // with nothing. Granting it would hand back `true`, and the caller would go on to
        // run a two-cat sequence with no cats in it.
        guard !pets.isEmpty else { return false }
        guard pets.allSatisfy({ isAvailable($0, for: activity) }) else { return false }

        for pet in pets { holders[pet] = activity }
        return true
    }

    /// Hand cats back, if `activity` is what is actually holding them.
    ///
    /// The guard is the whole method. A preempted activity is never told it lost. The
    /// cursor coordinator finds out only when its own release is quietly ignored, so an
    /// unconditional release would let it end the click reply that took its cat away, and
    /// the bubble would vanish mid-sentence for reasons nothing on screen could explain.
    public mutating func release(_ activity: PetActivity, pets: [Int]) {
        for pet in pets where holders.indices.contains(pet) && holders[pet] == activity {
            holders[pet] = nil
        }
    }

    /// The cast changed: forget every claim.
    ///
    /// Settings can add, drop or recolour a cat at any moment, and `Pet` objects are
    /// rebuilt rather than mutated when it does. A claim that survived would name an index
    /// into an array that has been replaced underneath it: at best a different cat, at
    /// worst one that is no longer on screen. Every claimant already has to cope with
    /// losing its cat mid-sequence (`advanceKiss` abandons on exactly this), so clearing
    /// is both the safe answer and the one they are all written for.
    public mutating func reset(petCount: Int) {
        holders = Array(repeating: nil, count: max(0, petCount))
    }

    /// How many cats this is keeping book for. For the verbose snapshot (SPEC §9).
    public var petCount: Int { holders.count }
}
