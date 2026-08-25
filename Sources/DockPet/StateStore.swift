//
//  StateStore.swift — [M11] state the app writes about itself.
//
//  Deliberately *not* config.json. That file is documented, hand-edited and owned by the
//  user; an app that rewrites it behind their back will eventually eat an edit. This is a
//  separate file next to it that nobody is invited to touch.
//

import Foundation

enum StateStore {

    /// [M11] Escape hatch for `--dedication-test`: with this set, `url` below is built from
    /// it instead of from `ConfigStore.directory`. That test mode has to say a real
    /// dedication to prove the positive path works at all, and the once-a-day gate lives
    /// entirely in this file's state.json — so without a way to redirect it, the only place
    /// left to write that stamp would be the user's real
    /// ~/Library/Application Support/DockPet/state.json. `nil` (the default) leaves every
    /// other launch mode pointed at the real file, exactly as before this existed.
    static var directoryOverride: URL?

    private static var directory: URL { directoryOverride ?? ConfigStore.directory }

    private static var url: URL {
        directory.appendingPathComponent("state.json")
    }

    private struct State: Codable {
        var lastGreetedDay: String?
        /// [M13] The day the birthday scene last ran, so it happens once and not on every
        /// poll of the morning. Separate from `lastGreetedDay` because they are different
        /// events on the one day both fire: the scene runs unprompted, the dedication is
        /// spent by a click, and sharing a stamp would let whichever came first silence
        /// the other for the rest of the day.
        var lastSceneDay: String?
    }

    private static func read() -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    /// The `Occasion.dayStamp` of the day the dedication was last said, or `nil` if it
    /// never has been. Every failure is silent by design: the cost of not being able to
    /// read or write this file is that a dedication is said twice, which nobody will
    /// notice, and it is not worth a launch or a log line.
    static var lastGreetedDay: String? {
        get { read().lastGreetedDay }
        set {
            var state = read()
            state.lastGreetedDay = newValue
            write(state)
        }
    }

    /// [M13] The `Occasion.dayStamp` of the day the birthday scene last ran, or `nil`.
    ///
    /// Stamped the moment the scene begins rather than when it finishes. A scene that is
    /// abandoned half way (a Dock that moved, a cast rebuilt underneath it) has still had
    /// its turn, and retrying it every 500 ms for the rest of her birthday would be far
    /// worse than missing it once.
    static var lastSceneDay: String? {
        get { read().lastSceneDay }
        set {
            var state = read()
            state.lastSceneDay = newValue
            write(state)
        }
    }

    /// Every failure is silent by design, for the reason given on `lastGreetedDay`.
    private static func write(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
