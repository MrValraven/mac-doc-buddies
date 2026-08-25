//
//  LoginItem.swift — register DockPet to start at login.
//
//  SPEC §7 M11a. §1 admits `ServiceManagement` for this and nothing else.
//
//  `SMAppService` requires a signed bundle, and DockPet is signed with a *local*
//  self-signed identity (§8.6 [M11]) that no other Mac trusts — so it was not a given that
//  registration would be accepted under that signature. It was verified directly against
//  the real, signed `.app` bundle built by bundle.sh: `SMAppService.mainApp.register()`
//  and `.unregister()` both succeed outright (status goes to `.enabled` / not registered,
//  never `.notFound`). There is no launchd fallback — this is the only mechanism.
//

import Foundation
import ServiceManagement

enum LoginItem {

    /// Every failure here is non-fatal, per §1: a login item that could not be registered
    /// costs a log line and an unticked checkbox, never a launch.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// For the launch log and the Settings window, which both need to say *why* a ticked
    /// box did not take effect. `.requiresApproval` is the interesting one: registration
    /// succeeded, and the user still has to allow it in System Settings.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:    return "not registered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "waiting for approval in System Settings › General › Login Items"
        case .notFound:         return "not found (run from the .app bundle, not the build directory)"
        @unknown default:       return "unknown"
        }
    }
}
