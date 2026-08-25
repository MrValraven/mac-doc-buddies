//
//  MenuBarItem.swift — the status item in the top-right of the menu bar.
//
//  DockPet is an LSUIElement app (SPEC §2): no Dock icon, no app menu bar. That leaves no
//  way to tell whether it is running, and no way to reach it short of `killall`. A status
//  item is the standard answer for a background app, and it does not conflict with
//  LSUIElement — that flag suppresses the app's own menu bar, not status items.
//

import AppKit
import DockPetCore

/// What the menu needs to know from the app, and what it can ask the app to do.
protocol MenuBarItemDelegate: AnyObject {
    /// One line describing what the pet is doing right now.
    var statusSummary: String { get }
    /// One line describing which sheets are loaded, so a reload's effect is visible.
    var spriteSummary: String { get }
    var isPaused: Bool { get }
    /// [M8] True while the pet is confined to the Dock's tiles.
    var isConfinedToDock: Bool { get }
    /// [M9] True when Accessibility has not been granted. Confinement is not optional, so
    /// without the grant the pet cannot appear at all — the menu item below is the fix.
    var needsAccessibilityGrant: Bool { get }
    func setPaused(_ paused: Bool)
    /// [M8] Show the system Accessibility prompt. Only ever reached by a click — never at
    /// launch, per SPEC §4c.
    func requestDockConfinement()
    /// Re-read config.json and the sprite sheets without restarting.
    func reload()
    /// Open the Settings window.
    func showSettings()
}

final class MenuBarItem: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sheetLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let confineItem = NSMenuItem(title: "Grant Accessibility…", action: nil,
                                         keyEquivalent: "")

    weak var delegate: MenuBarItemDelegate?

    init(version: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // A template image so the system tints it for light/dark menu bars rather than
            // leaving a fixed-colour blob.
            let image = NSImage(systemSymbolName: "cat.fill",
                                accessibilityDescription: "DockPet")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "DockPet \(version)"

            // If the symbol is ever unavailable, fall back to text rather than an item
            // that is invisible and unclickable.
            if button.image == nil { button.title = "🐈" }
        }

        buildMenu(version: version)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildMenu(version: String) {
        let header = NSMenuItem(title: "DockPet \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        sheetLine.isEnabled = false
        menu.addItem(sheetLine)

        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        // [M8] Hidden once the grant is in place — a permanent "grant me access" item in a
        // menu that already has access is just noise.
        confineItem.target = self
        confineItem.action = #selector(requestConfinement)
        confineItem.toolTip = "DockPet needs Accessibility to find the Dock's icons "
            + "before the cat can appear."
        menu.addItem(confineItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let spritesItem = NSMenuItem(title: "Reveal Sprites Folder…", action: #selector(revealSprites),
                                     keyEquivalent: "")
        spritesItem.target = self
        menu.addItem(spritesItem)

        let reloadItem = NSMenuItem(title: "Reload Sprites & Config", action: #selector(reload),
                                    keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit DockPet", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// What the status item is actually showing — used by `--menu-test` to confirm the
    /// cat symbol resolved rather than silently falling back to text.
    var iconDescription: String {
        guard let button = statusItem.button else { return "no button" }
        if button.image != nil { return "cat.fill symbol" }
        return "text fallback \"\(button.title)\""
    }

    /// Remove the item from the menu bar. Used when a reload turns `menuBarIcon` off.
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - NSMenuDelegate

    /// Refresh the live parts just before the menu is shown, rather than polling to keep a
    /// menu up to date that is closed almost all of the time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = delegate?.statusSummary ?? "Starting up…"
        sheetLine.title = delegate?.spriteSummary ?? ""
        pauseItem.title = (delegate?.isPaused ?? false) ? "Resume" : "Pause"
        // Shown only while the grant is missing — that is the only time it does anything.
        confineItem.isHidden = !(delegate?.needsAccessibilityGrant ?? false)
    }

    // MARK: - Actions

    @objc private func togglePause() {
        guard let delegate = delegate else { return }
        delegate.setPaused(!delegate.isPaused)
    }

    @objc private func requestConfinement() {
        delegate?.requestDockConfinement()
    }

    @objc private func openSettings() {
        delegate?.showSettings()
    }

    @objc private func revealSprites() {
        let dir = SpriteLoader.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    @objc private func reload() {
        delegate?.reload()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
