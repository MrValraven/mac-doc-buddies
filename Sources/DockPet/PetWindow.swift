//
//  PetWindow.swift — the borderless, click-through window the pet lives in.
//
//  SPEC §3. The window must never take focus, never appear in the window cycle, and never
//  draw above the menu bar.
//

import AppKit

final class PetWindow: NSWindow {

    init(contentRect: NSRect, content: NSView) {
        super.init(contentRect: contentRect,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)

        // Level 25. The Dock sits at 20 (confirmed in every PROBE.md run), so this floats
        // just above it. Deliberately NOT .screenSaver or higher: those draw over the menu
        // bar and over fullscreen apps.
        level = .statusBar

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // The pet is decoration; it must not participate in window restoration or leave
        // anything behind between launches.
        isRestorable = false
        isReleasedWhenClosed = false

        contentView = content
    }

    // SPEC §3: never key, never main. Use orderFront(_:), never makeKeyAndOrderFront(_:).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
