//
//  AppWatcher.swift, [M13] which app is in front, and nothing else.
//
//  The AppKit half of the reactions feature, and deliberately the thin half. Every
//  decision (whether the cat says anything, which line, and how often she is allowed to)
//  lives in `DockPetCore.ReactionCoordinator`, where it can be checked without a screen
//  and without waiting out an hour-long cooldown (SPEC §9). What is left here is one
//  observer registration and one delegate call.
//
//  SPEC §6: no timer, and no polling. This is event driven. The system already knows when
//  the frontmost application changes and says so; the app sleeps in between, and adds no
//  wakeup of its own.
//
//  **No new permission.** `NSWorkspace`'s activation notifications are ordinary public
//  application-lifecycle events: any app may observe them, with no entitlement, no
//  Accessibility grant and no consent prompt. This reads the bundle identifier of the app
//  that came to the front and nothing else. It cannot see windows, titles, documents or
//  input, and it needs none of those. The Accessibility grant DockPet already asks for is
//  for reading the Dock's tiles (§4b) and is unrelated to this file.
//

import AppKit

/// Told when the frontmost application changes.
protocol AppWatcherDelegate: AnyObject {

    /// A different app is now in front.
    ///
    /// `bundleID` is `nil` when the app has no bundle identifier at all, which is rare but
    /// real (some helper processes and command line tools). It is passed on rather than
    /// swallowed, because "an app with no identifier came to the front" is still a switch,
    /// and the coordinator's rule about coming straight back to the previous app needs to
    /// know it happened.
    func appWatcher(_ watcher: AppWatcher, didBringToFront bundleID: String?)
}

/// Watches for the frontmost application changing, and reports the bundle identifier.
///
/// No policy of any kind: it does not know what a cooldown is, does not decide whether
/// anything should be said, and holds no state beyond its observer token.
final class AppWatcher {

    weak var delegate: AppWatcherDelegate?

    /// The block observer's token, and the one piece of state here. Non-`nil` exactly while
    /// this watcher is registered, which is what makes `start` idempotent and `stop` safe
    /// to call twice.
    private var observer: NSObjectProtocol?

    var isWatching: Bool { observer != nil }

    /// Begin watching. Calling it again while already registered does nothing, rather than
    /// quietly stacking a second observer that would report every switch twice.
    func start() {
        guard observer == nil else { return }

        // `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`. These
        // notifications are posted to the workspace's own centre, and registering on the
        // default centre is the classic version of this mistake: it compiles, it runs, and
        // it never fires once.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication

            // DockPet's own activation is not an app switch the user made. The pet is an
            // accessory app that is never meant to be frontmost, but opening the click
            // menu or the Settings window can briefly make it so, and a cat remarking on
            // her own menu would be the feature commenting on itself.
            //
            // Filtered here rather than in the coordinator because that type is pure: it
            // is handed bundle identifiers as plain strings and has no way to know which
            // one is this process, and giving it one would mean giving it a way to ask the
            // running system questions.
            guard app?.processIdentifier != NSRunningApplication.current.processIdentifier
            else { return }

            self.delegate?.appWatcher(self, didBringToFront: app?.bundleIdentifier)
        }
    }

    /// Stop watching, and unregister.
    ///
    /// Removed from the same centre it was added to (see `start`), which is the other half
    /// of that trap: removing a workspace observer from the default centre leaves the real
    /// registration in place, and the block outlives the object that owns it.
    func stop() {
        guard let observer = observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        // The block above captures `self` weakly, so it cannot keep this object alive, and
        // a watcher that is deallocated without a matching `stop` still has to leave the
        // workspace's centre clean.
        stop()
    }
}
