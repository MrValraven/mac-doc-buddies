//
//  AmbientDirector.swift: [M13] the three things the cats do on their own, and the one
//  table that stops them fighting over the same cat.
//
//  Watching the cursor, walking to a Dock tile to sleep on, and remarking on the app she
//  just brought to the front. None of them is asked for, all three can want the same cat in
//  the same tick, and all three must lose to anything she did on purpose.
//
//  Which is why none of them tests a pile of `kiss == nil && !isTalking` for itself.
//  `PetOccupancy` holds the priority order and each feature asks it, so adding the next
//  claimant is one case in an enum rather than an edit to five call sites that all fail
//  silently when they disagree (see Occupancy.swift).
//
//  A file of its own, alongside SceneDirector, for the reason given there: AppDelegate is
//  1900 lines and M11c's goal was to shrink it, so only the stored state lives over there.
//

import AppKit
import DockPetCore

extension AppDelegate {

    // MARK: - Availability

    /// Whether an autonomous feature may take this cat right now.
    ///
    /// One question, asked per tick rather than stored, because every input can change
    /// between two frames: Settings can rebuild the cast, a click can start a sentence, a
    /// kiss can begin. A stored flag would be a cache of six things that each go stale on
    /// their own schedule.
    func isFree(_ pet: Pet, for activity: PetActivity) -> Bool {
        guard !paused, currentLocation != nil, pet.window.isVisible else { return false }
        // The things that hold a cat without going through the occupancy table, because
        // they predate it: a bubble, and the kiss's steering.
        guard !pet.interaction.isTalking, !pet.interaction.isPurring, !isSteered(pet) else {
            return false
        }
        return occupancy.isAvailable(pet.index, for: activity)
            || occupancy.activity(of: pet.index) == activity
    }

    // MARK: - [M13] Watching the cursor

    /// One frame of attention. Called from the animation tick, after the pair sequences
    /// have had their say, so a cat that a kiss or the scene is steering is already
    /// unavailable by the time this asks.
    func advanceAttention(by dt: TimeInterval, on strip: WalkStrip) {
        guard config.attention else { return }

        let candidates = pets.map {
            AttentionCoordinator.Candidate(index: $0.index,
                                           frame: $0.window.frame,
                                           isAvailable: isFree($0, for: .attention))
        }

        let focus = attention.advance(by: dt, on: strip, candidates: candidates)

        // Hand back any cat this had and no longer has, before claiming the new one. A cat
        // released after the claim would release the claim just made, when the focus moved
        // from one cat to the other and both lines named `.attention`.
        for pet in pets where pet.index != focus?.petIndex {
            occupancy.release(.attention, pets: [pet.index])
        }

        guard let focus, let pet = pets.first(where: { $0.index == focus.petIndex }) else {
            return
        }
        guard occupancy.activity(of: pet.index) == .attention
                || occupancy.claim(.attention, pets: [pet.index]) else { return }

        // `.idle` while it notices, `.sit` once it settles. Both are stationary, so the
        // existing "only walking moves the pet" rule does the stopping and this needs no
        // switch of its own.
        if pet.behavior.state != focus.petState {
            pet.behavior.force(focus.petState)
            pet.applyBehaviorState(focus.petState, spriteSet: sprites(for: pet))
        }
        pet.view.facing = focus.facing == .forward ? .right : .left
        // So it resumes walking the way it was left looking, rather than moonwalking off.
        if pet.walker.direction != focus.facing { pet.walker.reverse() }
    }

    /// The cursor moved. The one caller of `noteCursor`, and it decides nothing itself.
    func cursorWatcher(_ watcher: CursorWatcher, movedTo point: CGPoint) {
        guard config.attention else { return }
        attention.noteCursor(point)

        // SPEC §6 wake-up. The coordinator's clock rides on the animation tick, and that
        // tick suspends when every cat is stationary, so a pointer arriving while all of
        // them sit still would never be advanced into an episode at all.
        if let location = currentLocation,
           let strip = Geometry.walkStrip(on: DockLocator.geometry(of: location.screen),
                                          policy: .horizontalOnly, tiles: location.tiles),
           AttentionCoordinator.isNear(point, strip: strip) {
            updateAnimationState()
        }
    }

    // MARK: - [M13] Napping on a Dock icon

    /// A cat has just decided to sleep: send it to a tile first, if there is one to go to.
    ///
    /// Called from the 500 ms poll, where the behaviour transition is noticed. Nil means no
    /// trip, which is exactly today's behaviour of sleeping where it stands, and is what an
    /// ungranted app gets every time.
    func beginNapTrip(for pet: Pet, on location: DockLocation) {
        guard occupancy.isAvailable(pet.index, for: .napSpot) else { return }
        // The individual tile frames, not `location.tiles`, which is their union and
        // carries no idea where one icon ends and the next begins. Read here rather than
        // cached on the poll because it costs 7 to 9 ms (PROBE F7) and a cat decides to
        // sleep a few times an hour, so paying for it on every poll would be paying it a
        // hundred times over for one use.
        guard let tiles = DockTiles.tileFrames(on: location.screen), !tiles.isEmpty else {
            return   // no grant, or an empty Dock: sleep where it stands, as it always did
        }

        guard let spot = NapSpot.choose(from: tiles, petSize: pet.size,
                                        on: location.strip, using: &napRng) else { return }
        guard occupancy.claim(.napSpot, pets: [pet.index]) else { return }

        pet.napTrip = NapTrip(spot: spot)
        // The walk sheet, not the sleep pose: it is about to walk. Without this the cat
        // slides to the tile lying down, and SPEC §6's stationary rule would suspend the
        // timer under it so it would slide in 500 ms jumps.
        pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
        logLocation("pet \(pet.index): walking to Dock tile \(spot.index) to sleep on it")
    }

    /// One frame of a nap trip. Returns whether this pet's position is being driven here.
    func advanceNapTrip(for pet: Pet, by dt: TimeInterval, on strip: WalkStrip) -> Bool {
        guard var trip = pet.napTrip else { return false }

        // The cat stopped wanting to sleep: a click, the dwell expiring, a kiss taking it.
        guard pet.behavior.state == .sleep, isFree(pet, for: .napSpot) else {
            endNapTrip(for: pet, reason: "it stopped wanting to")
            return false
        }

        let maximum = Geometry.maximumDistance(for: pet.size, on: strip)
        let arrived = pet.walker.walk(toward: trip.target(for: pet.size, on: strip),
                                      by: dt, maxDistance: maximum)
        let progress = trip.advance(by: dt, arrived: arrived)
        pet.napTrip = trip
        pet.view.facing = pet.walker.direction == .forward ? .right : .left

        switch progress {
        case .travelling:
            return true
        case .arrived:
            logLocation("pet \(pet.index): asleep on Dock tile \(trip.tileIndex)")
            endNapTrip(for: pet, reason: nil)
            return false
        case .abandoned:
            // Not a failure. The ceiling exists so the cat is actually seen asleep rather
            // than spending its whole dwell walking; giving up and sleeping here is the
            // feature working, not breaking.
            logLocation("pet \(pet.index): too far to reach tile \(trip.tileIndex),"
                        + " sleeping where it stands")
            endNapTrip(for: pet, reason: nil)
            return false
        }
    }

    /// Hand the cat back and put it into the sleep it set out for.
    func endNapTrip(for pet: Pet, reason: String?) {
        guard pet.napTrip != nil else { return }
        pet.napTrip = nil
        occupancy.release(.napSpot, pets: [pet.index])
        if let reason { logLocation("pet \(pet.index): nap trip abandoned, \(reason)") }
        // Whatever ended the trip, the sheet must match the state the machine is in, or the
        // cat keeps the walk sheet while standing still.
        pet.applyBehaviorState(pet.behavior.state, spriteSet: sprites(for: pet))
    }

    // MARK: - [M13] Remarking on the frontmost app

    /// She brought an app to the front.
    ///
    /// Every rate limit lives in `ReactionCoordinator`; this decides only whether there is a
    /// cat free to say anything, and presents whatever comes back. A `nil` return spends no
    /// cooldown, so a suppressed remark is judged again on the next switch.
    func appWatcher(_ watcher: AppWatcher, didBringToFront bundleID: String?) {
        // The nearest thing to "whichever cat is free": the first one that is, so a sleeping
        // or talking cat does not silence the other.
        guard let pet = pets.first(where: { isFree($0, for: .reacting) }) else {
            // Still offered, with `canSpeak: false`, so the coordinator can record that a
            // switch happened without spending anything on it. Its return-window and
            // already-in-front rules need to see every switch, not only the ones that spoke.
            _ = reactions.appActivated(bundleID, name: nil,
                                       reactionsAllowed: config.reactions, canSpeak: false)
            return
        }

        let name = interactionUserName(for: pet.interaction)
        guard let line = reactions.appActivated(bundleID, name: name,
                                                reactionsAllowed: config.reactions,
                                                canSpeak: true) else { return }

        // Parked in idle for the length of the bubble, the same way every click reply is,
        // so the cat does not walk out from under a sentence nobody asked it for.
        pet.behavior.force(.idle)
        pet.applyBehaviorState(.idle, spriteSet: sprites(for: pet))
        print("[pet] reaction to \(bundleID ?? "an app with no id") → \"\(line)\"")
        pet.interaction.showBubble(line)
    }
}
