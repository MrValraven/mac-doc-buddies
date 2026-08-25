//
//  SettingsWindow.swift — the Settings window behind the menu bar item.
//
//  SPEC §1 allows SwiftUI inside a window's content view, but this stays AppKit: the rest
//  of the app is AppKit, the form is four controls, and a second UI paradigm would cost
//  more than it saves here.
//
//  Changes apply live. There is no OK/Cancel, because the result of every setting is
//  visible on screen the moment it changes — dragging the speed slider makes the cat
//  speed up. The config file is written on a short debounce so a slider drag is one write
//  rather than fifty.
//

import AppKit
import DockPetCore

protocol SettingsWindowDelegate: AnyObject {
    var currentConfig: PetConfig { get }
    /// One sprite frame in pixels, so the size popup can show what each scale produces.
    var spriteFrameSize: CGSize { get }
    /// Whether Dock confinement is actually in effect, phrased for the hint under the box.
    var confinementStatus: String { get }
    func settingsDidChange(_ config: PetConfig)
}

final class SettingsWindow: NSWindow, NSTextFieldDelegate {

    weak var settingsDelegate: SettingsWindowDelegate?

    private let speedSlider = NSSlider()
    private let speedValue = NSTextField(labelWithString: "")
    private let colorPopup = NSPopUpButton()
    private let scalePopup = NSPopUpButton()
    private let screenPopup = NSPopUpButton()
    private let menuBarCheck = NSButton(checkboxWithTitle: "Show the cat in the menu bar",
                                        target: nil, action: nil)
    /// [M11] Register DockPet as a login item, so the pet survives a reboot.
    private let loginCheck = NSButton(checkboxWithTitle: "Start DockPet when I log in",
                                      target: nil, action: nil)
    /// [M10] What the pet calls you when you click it and ask it to say hello.
    private let nameField = NSTextField(string: "")
    /// [M9] Confinement is not optional, so there is no control for it — only a line
    /// saying whether Accessibility has been granted yet.
    private let confineHint = SettingsWindow.hint("")

    /// Scales offered in the popup. config.json accepts 1...8 for hand-editing; anything
    /// outside this list is added on the fly so the UI never silently changes it.
    private static let offeredScales = [1, 2, 3, 4]

    init(delegate: SettingsWindowDelegate) {
        self.settingsDelegate = delegate
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)

        title = "DockPet Settings"
        isReleasedWhenClosed = false
        // Follow the pet across Spaces, so the window opens where you are.
        collectionBehavior = [.moveToActiveSpace]

        buildLayout()
        loadFromConfig()
        center()
    }

    // MARK: - Layout

    private func buildLayout() {
        let content = NSView()

        speedSlider.minValue = 5
        speedSlider.maxValue = 200
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(controlChanged)

        speedValue.alignment = .right
        speedValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        speedValue.setContentHuggingPriority(.required, for: .horizontal)

        let speedRow = NSStackView(views: [speedSlider, speedValue])
        speedRow.orientation = .horizontal
        speedRow.spacing = 10

        let speedHint = Self.hint("Around 20 px/s matches the walk animation's stride, so the paws don't slip.")

        colorPopup.target = self
        colorPopup.action = #selector(controlChanged)

        scalePopup.target = self
        scalePopup.action = #selector(controlChanged)

        screenPopup.target = self
        screenPopup.action = #selector(controlChanged)

        nameField.target = self
        // Applied on Return or when the field loses focus, not per keystroke: `action`
        // alone would save a config for every prefix of the name being typed.
        nameField.action = #selector(controlChanged)
        nameField.delegate = self
        nameField.placeholderString = "Your name"
        let nameHint = Self.hint("Click the cat and pick a prompt — it answers in a speech bubble. "
                                 + "Leave this empty and it greets you without a name.")

        menuBarCheck.target = self
        menuBarCheck.action = #selector(controlChanged)
        let menuBarHint = Self.hint("With this off, DockPet can only be quit with `killall DockPet`.")

        loginCheck.target = self
        loginCheck.action = #selector(controlChanged)

        let grid = NSGridView(views: [
            [Self.label("Walking speed:"), speedRow],
            [NSGridCell.emptyContentView, speedHint],
            [Self.label("Coat:"), colorPopup],
            [Self.label("Size:"), scalePopup],
            [Self.label("Display:"), screenPopup],
            [Self.label("Walk area:"), confineHint],
            [Self.label("Call me:"), nameField],
            [NSGridCell.emptyContentView, nameHint],
            [NSGridCell.emptyContentView, menuBarCheck],
            [NSGridCell.emptyContentView, menuBarHint],
            [NSGridCell.emptyContentView, loginCheck],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        // Tuck each hint up under the control it explains. The rows are found by looking
        // for the hint views themselves rather than by index: a hardcoded index is an
        // out-of-range crash the first time somebody inserts a row above it, and this
        // layout has now been added to twice.
        let hints: [NSView] = [speedHint, nameHint, menuBarHint]
        for row in 0..<grid.numberOfRows {
            let cells = (0..<grid.numberOfColumns).map { grid.cell(atColumnIndex: $0, rowIndex: row).contentView }
            if cells.contains(where: { view in hints.contains { $0 === view } }) {
                grid.row(at: row).topPadding = -6
            }
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset to Defaults", target: self,
                                   action: #selector(resetToDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(separator)
        content.addSubview(resetButton)
        content.addSubview(doneButton)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            resetButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            resetButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            doneButton.centerYAnchor.constraint(equalTo: resetButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            speedSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        contentView = content
    }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    /// A small chip of the coat colour, so the list can be read at a glance rather than
    /// by translating six colour names into cats.
    ///
    /// Drawn from the palette's own `coat` value, so a palette edit reaches the popup for
    /// free and the swatch can never disagree with the cat.
    private static func swatch(for palette: CatPalette) -> NSImage {
        let side: CGFloat = 14
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let box = NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: CGFloat(palette.coat.red) / 255,
                green: CGFloat(palette.coat.green) / 255,
                blue: CGFloat(palette.coat.blue) / 255, alpha: 1).setFill()
        path.fill()
        // A hairline keeps the white and cream coats from vanishing into a light menu.
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    private static func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: - Config <-> controls

    /// Rebuild the controls from the current config. Also called when the window is
    /// re-opened, so it never shows stale values after a reload.
    func loadFromConfig() {
        guard let delegate = settingsDelegate else { return }
        let config = delegate.currentConfig

        speedSlider.doubleValue = config.speed
        updateSpeedLabel()

        colorPopup.removeAllItems()
        for palette in CatPalette.all {
            colorPopup.addItem(withTitle: palette.displayName)
            colorPopup.lastItem?.representedObject = palette.id
            colorPopup.lastItem?.image = Self.swatch(for: palette)
        }
        // An id the popup does not offer can only come from a hand-edited config.json, and
        // validation has already replaced it by now — but selecting nothing would show the
        // first coat while the pet wore another, so fall back explicitly.
        let coatIndex = colorPopup.itemArray.firstIndex { ($0.representedObject as? String) == config.color }
        colorPopup.selectItem(at: coatIndex ?? 0)

        var scales = Self.offeredScales
        if !scales.contains(config.scale) { scales.append(config.scale); scales.sort() }
        scalePopup.removeAllItems()
        let frame = delegate.spriteFrameSize
        for scale in scales {
            let w = Int(frame.width) * scale, h = Int(frame.height) * scale
            scalePopup.addItem(withTitle: "\(scale)×  (\(w)×\(h) pt)")
            scalePopup.lastItem?.tag = scale
        }
        scalePopup.selectItem(withTag: config.scale)

        screenPopup.removeAllItems()
        screenPopup.addItem(withTitle: "Automatic (follow the Dock)")
        screenPopup.lastItem?.representedObject = nil
        for screen in NSScreen.screens {
            screenPopup.addItem(withTitle: screen.localizedName)
            screenPopup.lastItem?.representedObject = screen.localizedName
        }
        // A pinned display that is currently unplugged must still show as selected, rather
        // than silently reverting to Automatic.
        if let pinned = config.screen {
            if !NSScreen.screens.contains(where: { $0.localizedName == pinned }) {
                screenPopup.addItem(withTitle: "\(pinned) (not connected)")
                screenPopup.lastItem?.representedObject = pinned
            }
            let index = screenPopup.itemArray.firstIndex {
                ($0.representedObject as? String) == pinned
            }
            screenPopup.selectItem(at: index ?? 0)
        } else {
            screenPopup.selectItem(at: 0)
        }

        menuBarCheck.state = config.menuBarIcon ? .on : .off
        loginCheck.state = config.launchAtLogin ? .on : .off
        nameField.stringValue = config.userName ?? ""

        // No control here: the pet is always confined. This only reports whether the
        // Accessibility grant that makes it possible is in place.
        confineHint.stringValue = delegate.confinementStatus
    }

    private func updateSpeedLabel() {
        speedValue.stringValue = String(format: "%.0f px/s", speedSlider.doubleValue)
    }

    private func currentValues() -> PetConfig {
        PetConfig(speed: speedSlider.doubleValue.rounded(),
                  scale: scalePopup.selectedItem?.tag ?? 2,
                  screen: screenPopup.selectedItem?.representedObject as? String,
                  menuBarIcon: menuBarCheck.state == .on,
                  color: colorPopup.selectedItem?.representedObject as? String
                      ?? CatPalette.default.id,
                  // Trimming and length are `PetConfig.validated`'s job, so a name typed
                  // here and a name hand-edited into config.json get the same treatment.
                  userName: nameField.stringValue.isEmpty ? nil : nameField.stringValue,
                  launchAtLogin: loginCheck.state == .on)
    }

    // MARK: - Actions

    @objc private func controlChanged() {
        updateSpeedLabel()
        settingsDelegate?.settingsDidChange(currentValues())
    }

    @objc private func resetToDefaults() {
        settingsDelegate?.settingsDidChange(.default)
        loadFromConfig()
    }

    @objc private func closeWindow() {
        close()
    }

    /// [M10] Commit the name when focus leaves the field.
    ///
    /// Without this, typing a name and clicking Done straight away would close the window
    /// on an uncommitted field and lose it — the one path through this window where a
    /// setting could be silently dropped.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === nameField else { return }
        settingsDelegate?.settingsDidChange(currentValues())
    }

    /// Exposed so `--settings-test` can drive the controls the way a click would.
    /// The coats currently in the popup, in order. Exposed so `--settings-test` can check
    /// the list rather than trusting that it was built.
    var offeredCoatIDs: [String] {
        colorPopup.itemArray.compactMap { $0.representedObject as? String }
    }

    func simulate(speed: Double? = nil, scale: Int? = nil, screen: String?? = nil,
                  menuBarIcon: Bool? = nil, color: String? = nil, userName: String? = nil,
                  launchAtLogin: Bool? = nil) {
        if let userName { nameField.stringValue = userName }
        if let speed { speedSlider.doubleValue = speed }
        if let scale { scalePopup.selectItem(withTag: scale) }
        if let screen {
            let index = screenPopup.itemArray.firstIndex { ($0.representedObject as? String) == screen }
            screenPopup.selectItem(at: index ?? 0)
        }
        if let menuBarIcon { menuBarCheck.state = menuBarIcon ? .on : .off }
        if let launchAtLogin { loginCheck.state = launchAtLogin ? .on : .off }
        if let color {
            let index = colorPopup.itemArray.firstIndex { ($0.representedObject as? String) == color }
            colorPopup.selectItem(at: index ?? 0)
        }
        controlChanged()
    }

    func simulateReset() { resetToDefaults() }
}
