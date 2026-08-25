//
//  ConfigStore.swift — reads (and seeds) ~/Library/Application Support/DockPet/config.json
//
//  SPEC §7 M6. Parsing and validation live in DockPetCore.PetConfig; this file is only the
//  file IO around them.
//

import Foundation
import DockPetCore

enum ConfigStore {

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockPet", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("config.json") }

    struct Outcome {
        let config: PetConfig
        /// Human-readable account of what happened, for the launch log.
        let notes: [String]
    }

    /// Load the config, writing a default file the first time so there is something to
    /// edit rather than a documented-but-absent path.
    ///
    /// Every failure is non-fatal: a broken config file costs you a log line and the
    /// defaults, never a launch.
    static func load() -> Outcome {
        var notes: [String] = []

        guard FileManager.default.fileExists(atPath: url.path) else {
            switch write(PetConfig.default) {
            case .success:
                notes.append("wrote a default config to \(url.path)")
            case .failure(let error):
                notes.append("could not write a default config (\(error.localizedDescription))")
            }
            return Outcome(config: Self.validatedDefaults, notes: notes)
        }

        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONDecoder().decode(PetConfig.self, from: data)
            let (config, corrections) = parsed.validated()
            for correction in corrections {
                notes.append("\(correction.field)=\(correction.given) is out of range, using \(correction.used)")
            }
            notes.append("loaded \(url.path)")
            return Outcome(config: config, notes: notes)
        } catch {
            notes.append("could not read config.json (\(error)) — using defaults")
            return Outcome(config: Self.validatedDefaults, notes: notes)
        }
    }

    /// The defaults, *put through the validator* — because everything downstream is
    /// written against a validated config.
    ///
    /// `PetConfig.default` is a bare initialiser: its `pets` array is empty, and
    /// `validated()` is what fills it in with pet 0. Handing the bare defaults out on the
    /// two fallback paths above meant that a Mac with no config.json — every Mac, on its
    /// first launch — loaded a config describing no cats at all, which the launch sequence
    /// reads as "no sprite sheets to load" and exits on. The second launch worked, because
    /// the first one wrote the file before dying. Validated here, at the source, so the
    /// invariant the rest of the app relies on holds on every path out of `load()`.
    private static var validatedDefaults: PetConfig { PetConfig.default.validated().config }

    @discardableResult
    static func write(_ config: PetConfig) -> Result<Void, Error> {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
