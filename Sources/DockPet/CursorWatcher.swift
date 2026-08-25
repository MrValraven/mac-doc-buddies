//
//  CursorWatcher.swift: [M13] where the pointer is, and nothing else.
//
//  The AppKit half of the attention feature, and deliberately the smaller half. Every
//  decision (is the pointer near the Dock, which cat is nearest, which way it faces, how
//  long before it sits, when it may happen again) lives in `AttentionCoordinator` in
//  DockPetCore, where a test can drive a pointer that does not exist. What is left here is a
//  monitor, a throttle and a delegate call, which is little enough to be checked by reading.
//
//  SPEC §6: this adds **no timer**. It is event driven, and the throttle below is a
//  comparison against the time of the last report rather than anything scheduled. A monitor
//  that is silent while the mouse is still costs nothing, which is most of the day.
//

import AppKit
import QuartzCore
import DockPetCore

protocol CursorWatcherDelegate: AnyObject {
    /// The pointer has moved, in AppKit screen coordinates (bottom-left origin, y upward,
    /// anchored on the primary screen), which is the same space as `NSWindow.frame` and
    /// `WalkStrip`. No conversion is required or performed anywhere in this feature, which
    /// is the point: SPEC §8 trap 1 is that coordinate conversions written more than once
    /// get written differently.
    func cursorWatcher(_ watcher: CursorWatcher, movedTo point: CGPoint)
}

/// A throttled global mouse monitor. Reports where the pointer is; decides nothing.
final class CursorWatcher {

    weak var delegate: CursorWatcherDelegate?

    private var monitor: Any?

    /// When the last report went out, on the same monotonic clock `AppDelegate` uses for the
    /// animation tick. `CACurrentMediaTime` rather than `Date`: this measures an interval,
    /// and a wall clock that a time zone change or an NTP correction can move backwards
    /// would silently stop the throttle letting anything through.
    private var lastReport: CFTimeInterval = 0

    /// Start watching. Safe to call when already started.
    func start() {
        guard monitor == nil else { return }

        // Global, for the reason `PetInteraction.startMouseTracking()` gives: DockPet is an
        // accessory app that is never frontmost, so the mouse events that matter all happen
        // in *other* applications, and a local monitor would see none of them. Mouse
        // monitors need no permission of their own; only keyboard ones do, which is why this
        // works with nothing but the Accessibility grant the Dock tiles already require, and
        // works without even that.
        //
        // `.mouseMoved` only. `.leftMouseDragged` was considered and left out: a drag is a
        // file being carried to a Dock icon, and a cat that stops and sits in the middle of
        // a drag is standing on the one part of the screen the user is aiming at. The cat
        // simply does not notice while something is being dragged, which is the polite
        // answer.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.report()
        }
    }

    /// Stop watching, and release the monitor.
    ///
    /// Explicit rather than left to `deinit`, for the reason `Pet.teardown()` exists: a live
    /// global monitor behind a torn-down feature keeps firing, and nothing on screen says
    /// why the app is still doing work.
    func stop() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }

    private func report() {
        // Throttled to `AttentionCoordinator.reportInterval`. A gaming mouse can deliver
        // `.mouseMoved` faster than 200 Hz, and the decision that consumes these runs on the
        // 12 fps animation tick regardless, so everything above about 20 Hz is work whose
        // result is overwritten before anything reads it.
        //
        // The event's own location is deliberately not used. `NSEvent.mouseLocation` is the
        // documented way to ask where the pointer is now, and "now" is the honest answer
        // after a throttle has just dropped several events: reporting the position from the
        // one event that happened to survive would hand back a point the pointer has already
        // left.
        let now = CACurrentMediaTime()
        guard now - lastReport >= AttentionCoordinator.reportInterval else { return }
        lastReport = now

        delegate?.cursorWatcher(self, movedTo: NSEvent.mouseLocation)
    }
}
