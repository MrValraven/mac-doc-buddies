//
//  OccupancyTests.swift: [M13] who owns a cat right now, and who is allowed to take it.
//
//  SPEC §9: none of this is visible on screen, and a feature that quietly loses a contest it
//  should have won looks exactly like a feature that is simply not very active. So the
//  contests are decided here, in a table, rather than discovered on the Dock.
//

import Foundation
import DockPetCore

enum OccupancyTests {

    static func run() {
        section("[M13] PetActivity: the priority order")

        do {
            // Spelled out as a list rather than asserted pairwise: the order *is* the
            // design, and a reader who wants to know whether a click beats a meeting
            // should be able to read the answer rather than derive it.
            let ascending: [PetActivity] = [.attention, .napSpot, .reacting, .meeting,
                                            .talking, .petted, .kiss, .scene]
            var sorted = true
            for (lower, higher) in zip(ascending, ascending.dropFirst()) where !(lower < higher) {
                sorted = false
            }
            check(sorted, "the documented order is the order the type actually sorts in")
        }

        do {
            check(PetActivity.attention < PetActivity.talking,
                  "watching the cursor never interrupts the cat answering a click")
            check(PetActivity.reacting < PetActivity.talking,
                  "a remark about an app never interrupts a reply she asked for")
            check(PetActivity.meeting < PetActivity.petted,
                  "two cats do not start chatting while she has her finger on one of them")
            check(PetActivity.meeting < PetActivity.talking,
                  "and a click interrupts a meeting, which is what the app already does today")
            check(PetActivity.napSpot < PetActivity.meeting,
                  "walking to a Dock tile yields to actually meeting the other cat")
            check(PetActivity.scene > PetActivity.kiss,
                  "the birthday scene outranks everything, because it happens once a year")
        }

        section("[M13] PetOccupancy: claiming a single cat")

        do {
            var occupancy = PetOccupancy(petCount: 2)
            eq(occupancy.activity(of: 0), nil, "a fresh cat is owned by nobody")
            check(occupancy.isAvailable(0, for: .attention), "and is available to anything")

            check(occupancy.claim(.attention, pets: [0]), "the first claim is granted")
            eq(occupancy.activity(of: 0), .attention, "and is recorded")
            check(!occupancy.isAvailable(0, for: .attention),
                  "an activity cannot claim a cat it already holds, which would restart it")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.talking, pets: [0]), "the cat is answering a click")
            check(!occupancy.claim(.attention, pets: [0]),
                  "a lower-priority activity is refused rather than queued")
            eq(occupancy.activity(of: 0), .talking, "and the holder is untouched by the attempt")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.attention, pets: [0]), "the cat is watching the cursor")
            check(occupancy.claim(.talking, pets: [0]), "a click takes it away")
            eq(occupancy.activity(of: 0), .talking, "and becomes the holder")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.napSpot, pets: [0]), "cat 0 is walking to a tile")
            check(occupancy.claim(.napSpot, pets: [1]), "cat 1 may do the same thing at once")
            eq(occupancy.activity(of: 0), .napSpot, "the cats are tracked separately")
            eq(occupancy.activity(of: 1), .napSpot, "both of them")
        }

        section("[M13] PetOccupancy: a claim on the pair is all or nothing")

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.talking, pets: [1]), "cat 1 is mid-sentence")
            check(!occupancy.claim(.meeting, pets: [0, 1]),
                  "so the pair cannot be claimed for a meeting")
            eq(occupancy.activity(of: 0), nil,
               "and cat 0 is left alone, because a half-granted meeting would strand it mid-walk")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.attention, pets: [0]), "cat 0 is watching the cursor")
            check(occupancy.claim(.kiss, pets: [0, 1]),
                  "a kiss outranks it, so the pair is taken")
            eq(occupancy.activity(of: 0), .kiss, "cat 0 changes hands")
            eq(occupancy.activity(of: 1), .kiss, "and cat 1 is taken in the same breath")
        }

        section("[M13] PetOccupancy: releasing")

        do {
            var occupancy = PetOccupancy(petCount: 2)
            occupancy.claim(.kiss, pets: [0, 1])
            occupancy.release(.kiss, pets: [0, 1])
            eq(occupancy.activity(of: 0), nil, "releasing hands the cat back")
            eq(occupancy.activity(of: 1), nil, "both of them")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            occupancy.claim(.attention, pets: [0])
            occupancy.claim(.talking, pets: [0])
            // The attention coordinator does not know it lost. It finds out by releasing
            // and being ignored. Without this rule it would take the click's turn away.
            occupancy.release(.attention, pets: [0])
            eq(occupancy.activity(of: 0), .talking,
               "an activity that was preempted cannot release the one that took its place")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            occupancy.release(.talking, pets: [0])
            eq(occupancy.activity(of: 0), nil, "releasing a cat nobody holds is harmless")
        }

        section("[M13] PetOccupancy: a cast that changes under it")

        do {
            var occupancy = PetOccupancy(petCount: 2)
            occupancy.claim(.kiss, pets: [0, 1])
            occupancy.reset(petCount: 1)
            eq(occupancy.activity(of: 0), nil,
               "Settings dropping the second cat clears every claim, so nothing holds a cat "
                 + "that is no longer on screen")
        }

        do {
            var occupancy = PetOccupancy(petCount: 1)
            // Every index the app can produce is a real cat, but the app has been wrong
            // before, so an out-of-range read must be an answer, not a crash on her Dock.
            eq(occupancy.activity(of: 7), nil, "an index past the cast is owned by nobody")
            check(!occupancy.isAvailable(7, for: .kiss), "and is never available")
            check(!occupancy.claim(.kiss, pets: [0, 7]),
                  "a pair claim naming a cat that does not exist is refused entirely")
            eq(occupancy.activity(of: 0), nil, "leaving the real cat untouched")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(!occupancy.claim(.kiss, pets: []),
                  "a claim on no cats at all is refused rather than silently succeeding")
        }
    }
}
