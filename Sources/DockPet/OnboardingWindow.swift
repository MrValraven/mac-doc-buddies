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

        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)

        title = "DockPet"
        isReleasedWhenClosed = false
        center()

        let heading = NSTextField(labelWithString: "There's a cat for your Dock.")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "It walks along the top of your Dock and naps a lot. To find where your Dock "
            + "icons are, it needs Accessibility permission — that's the only thing it asks for.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

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
    }

    @objc private func grantPressed() {
        onGrant()
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
