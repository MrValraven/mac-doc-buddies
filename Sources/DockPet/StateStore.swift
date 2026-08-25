//
//  StateStore.swift — [M11] state the app writes about itself.
//
//  Deliberately *not* config.json. That file is documented, hand-edited and owned by the
//  user; an app that rewrites it behind their back will eventually eat an edit. This is a
//  separate file next to it that nobody is invited to touch.
//

import Foundation

enum StateStore {

    private static var url: URL {
        ConfigStore.directory.appendingPathComponent("state.json")
    }

    private struct State: Codable {
        var lastGreetedDay: String?
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
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? FileManager.default.createDirectory(at: ConfigStore.directory,
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
