//
//  OnboardingWindow.swift — the one thing shown to someone who has never seen this app.
//
//  SPEC §7 M11a. Appears only when Accessibility has not been granted. It is not a wizard
//  and not a welcome tour: one sentence, one button, and a status line that tells the
//  truth about whether the Dock has been found yet.
//

import AppKit

final class OnboardingWindow: NSWindow {

    private let statusLabel = NSTextField(labelWithString: "")
    private let grantButton: NSButton
    private let onGrant: () -> Void

    /// True once the Dock has been found and the window has taken itself down.
    private(set) var isFinished = false

    init(onGrant: @escaping () -> Void) {
        self.onGrant = onGrant
        self.grantButton = NSButton(title: "Open Accessibility Settings…",
                                    target: nil, action: nil)

        // Placeholder size only — the real size is computed below from the content once
        // it exists, rather than guessed here. A titled/closable window still needs some
        // starting contentRect to be constructed at all.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)

        title = "DockPet"
        isReleasedWhenClosed = false

        let heading = NSTextField(labelWithString: "There's a cat for your Dock.")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "It walks along the top of your Dock and naps a lot. To find where your Dock "
            + "icons are, it needs Accessibility permission — that's the only thing it asks for.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        // NSStackView's "leading" alignment pins only the leading edge of each arranged
        // subview, not the trailing one — without a width, this wrapping label lays out at
        // its near-single-line intrinsic width and gets clipped by the window edge instead
        // of wrapping. 380 = the 420pt column minus the stack's 20pt insets on each side.
        body.widthAnchor.constraint(equalToConstant: 380).isActive = true

        grantButton.target = self
        grantButton.action = #selector(grantPressed)
        grantButton.bezelStyle = .rounded
        grantButton.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Waiting for permission…"

        let stack = NSStackView(views: [heading, body, grantButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        contentView = container

        // Size the window to the content instead of a second hardcoded guess: the body
        // sentence's wrapped line count depends on the text, and a fixed height here would
        // repeat exactly the mistake the missing width constraint just made, one field over.
        let fitting = stack.fittingSize
        setContentSize(fitting)
        center()
    }

    @objc private func grantPressed() {
        onGrant()

        // Say what was just done. `onGrant` opens the Accessibility pane, and the system
        // alert that also deep-links there appears only the first time it is ever asked
        // for — so from the second press onwards this line is the only feedback the press
        // produces, and "Waiting for permission…" sitting unchanged reads as a dead button.
        // The poll replaces this with the real answer the moment the Dock is found.
        //
        // Kept to one short line on purpose: `statusLabel` is a non-wrapping label and the
        // window was sized to its content at init, so a sentence wider than the 380 pt
        // column would be clipped rather than wrapped.
        statusLabel.stringValue = "Opened Settings — tick DockPet in the list."
    }

    /// Called from the 500 ms poll the first time the Dock is actually located. Says so,
    /// then takes itself away — a window that stays up after it has been satisfied reads
    /// as something still being wrong.
    func markGranted() {
        guard !isFinished else { return }
        isFinished = true
        statusLabel.stringValue = "Found your Dock. Here comes the cat."
        statusLabel.textColor = .systemGreen
        grantButton.isEnabled = false

        // Long enough to be read, short enough not to be in the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.orderOut(nil)
        }
    }
}
