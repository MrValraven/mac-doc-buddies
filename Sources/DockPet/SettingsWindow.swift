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
    /// [M11] The second cat: whether there is one, and what it wears. The cap is two
    /// (SPEC §8.5 forbids a plugin system), so this is a checkbox rather than a list.
    private let secondCatCheck = NSButton(checkboxWithTitle: "A second cat",
                                          target: nil, action: nil)
    private let secondColorPopup = NSPopUpButton()
    /// [M12] Whether the two of them may kiss — the occasional one when they meet, and the
    /// *Kiss the other cat* item in the click menu. Meaningless with one cat, so it is
    /// enabled alongside the second cat's coat popup.
    private let kissCheck = NSButton(checkboxWithTitle: "Let them kiss",
                                     target: nil, action: nil)
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

    /// [M11] The cast exactly as it was last loaded from the config.
    ///
    /// This window owns two things about a cat: whether the second one exists, and what
    /// coat each wears. It does **not** own a cat's `name`, or a per-pet `userName` — both
    /// are hand-edited in config.json — so the profiles are carried through rather than
    /// rebuilt from the controls. Rebuilding them would silently delete a cat's name the
    /// first time anybody nudged the speed slider.
    private var loadedPets: [PetProfile] = []

    /// Scales offered in the popup. config.json accepts 1...8 for hand-editing; anything
    /// outside this list is added on the fly so the UI never silently changes it.
    private static let offeredScales = [1, 2, 3, 4]

    init(delegate: SettingsWindowDelegate) {
        self.settingsDelegate = delegate
        // [M11] Taller than M10's 260: the second cat added two rows and a hint, and the
        // grid is pinned to the top with the buttons pinned to the bottom, so the window
        // has to make the room itself.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
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

        secondCatCheck.target = self
        secondCatCheck.action = #selector(controlChanged)
        secondColorPopup.target = self
        secondColorPopup.action = #selector(controlChanged)
        kissCheck.target = self
        kissCheck.action = #selector(controlChanged)
        let secondCatHint = Self.hint("Two is the limit. The second cat walks the same Dock, "
                                      + "and when they meet they stop for a word — and now and "
                                      + "then, a kiss.")

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
            [NSGridCell.emptyContentView, secondCatCheck],
            [Self.label("Its coat:"), secondColorPopup],
            [NSGridCell.emptyContentView, kissCheck],
            [NSGridCell.emptyContentView, secondCatHint],
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
        let hints: [NSView] = [speedHint, nameHint, menuBarHint, secondCatHint]
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

        // [M11] Both coat popups are filled the same way, from the same catalogue: two
        // lists built separately would be the kind of thing that drifts by one coat.
        loadedPets = config.pets
        Self.fillCoats(colorPopup, selecting: config.color)
        Self.fillCoats(secondColorPopup, selecting: loadedPets.count > 1 ? loadedPets[1].color : nil)
        secondCatCheck.state = loadedPets.count > 1 ? .on : .off
        secondColorPopup.isEnabled = secondCatCheck.state == .on
        kissCheck.isEnabled = secondCatCheck.state == .on

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

        kissCheck.state = config.kisses ? .on : .off
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

    /// The config this window's controls describe.
    ///
    /// [M11] It **starts from the config that is live** and changes only the fields this
    /// window actually owns, rather than constructing a fresh `PetConfig` from the
    /// controls. Constructing one silently reset every key with no control here to its
    /// default — which meant `birthday` and `dedication`, the whole gift layer this
    /// milestone exists for, were wiped from disk the first time anybody nudged the speed
    /// slider, recoverable only by hand-editing JSON. Starting from the live config means
    /// the next key added to `PetConfig` cannot repeat that: a field nobody wires up here
    /// is carried through untouched instead of being quietly deleted.
    private func currentValues() -> PetConfig {
        var config = settingsDelegate?.currentConfig ?? .default

        let coat = colorPopup.selectedItem?.representedObject as? String ?? CatPalette.default.id
        // Trimming and length are `PetConfig.validated`'s job, so a name typed here and a
        // name hand-edited into config.json get the same treatment.
        let userName = nameField.stringValue.isEmpty ? nil : nameField.stringValue

        // [M11] Profiles are edited in place rather than rebuilt, for the same reason the
        // config is: a cat's own `name` has no control in this window and must survive
        // every other setting being changed.
        var pets = loadedPets.isEmpty ? [PetProfile()] : loadedPets
        pets[0].color = coat
        pets[0].userName = userName

        if secondCatCheck.state == .on {
            // The popup always has a selection — `fillCoats` ends on `selectItem(at:)` —
            // so this reads the coat `chooseCoatForANewSecondCat` just picked. The `??` is
            // for the unreachable case only; it must never be the thing that chooses a
            // coat, which is exactly the bug that shipped two identical cats.
            let second = secondColorPopup.selectedItem?.representedObject as? String
                ?? Self.coatUnlike(coat)
            if pets.count > 1 {
                pets[1].color = second
            } else {
                // A new second cat has no `userName` of its own on purpose: `nil` means it
                // inherits whatever *Call me* currently says, where a copy taken now would
                // quietly go stale the next time that field changed.
                pets.append(PetProfile(name: nil, color: second, userName: nil))
            }
        } else if pets.count > 1 {
            pets.removeSubrange(1...)
        }

        config.speed = speedSlider.doubleValue.rounded()
        config.scale = scalePopup.selectedItem?.tag ?? config.scale
        config.screen = screenPopup.selectedItem?.representedObject as? String
        config.kisses = kissCheck.state == .on
        config.menuBarIcon = menuBarCheck.state == .on
        config.launchAtLogin = loginCheck.state == .on
        config.color = coat
        config.userName = userName
        config.pets = pets
        return config
    }

    /// Fill a coat popup from the catalogue and select an id.
    ///
    /// An id the popup does not offer can only come from a hand-edited config.json, and
    /// validation has already replaced it by now — but selecting nothing would show the
    /// first coat while the cat wore another, so fall back explicitly.
    private static func fillCoats(_ popup: NSPopUpButton, selecting id: String?) {
        popup.removeAllItems()
        for palette in CatPalette.all {
            popup.addItem(withTitle: palette.displayName)
            popup.lastItem?.representedObject = palette.id
            popup.lastItem?.image = swatch(for: palette)
        }
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == id }
        popup.selectItem(at: index ?? 0)
    }

    /// A coat the first cat is not wearing, so a newly added second cat is visibly a
    /// second cat.
    ///
    /// Taken from the catalogue rather than named here. `CatPalette.all` leads with the
    /// default coat, so the second cat gets the default unless the first one is already
    /// wearing it — and nothing in this file has to be edited when the default changes.
    private static func coatUnlike(_ taken: String) -> String {
        CatPalette.all.first { $0.id != taken }?.id ?? CatPalette.default.id
    }

    // MARK: - Actions

    @objc private func controlChanged() {
        updateSpeedLabel()
        // A coat popup for a cat that does not exist is a control with nothing behind it,
        // and neither is a kissing toggle for a cat with nobody to kiss.
        secondColorPopup.isEnabled = secondCatCheck.state == .on
        kissCheck.isEnabled = secondCatCheck.state == .on
        chooseCoatForANewSecondCat()
        settingsDelegate?.settingsDidChange(currentValues())
        // Re-read the cast that actually took effect, so the next edit builds on it rather
        // than on the one this window happened to be opened with. Without this the block
        // above would keep believing the second cat is still new and would overrule the
        // coat the user picks for it a moment later.
        loadedPets = settingsDelegate?.currentConfig.pets ?? loadedPets
    }

    /// Give a **newly** added second cat a coat the first one is not wearing.
    ///
    /// Done here, before anything reads the popup — not as a `??` fallback behind it.
    /// `fillCoats` always ends on `selectItem(at:)`, so the popup's selection is never
    /// `nil` and such a fallback can never run: the new cat took whatever coat happens to
    /// lead the catalogue, which is the default coat and therefore usually the one the
    /// first cat is already wearing. Two identical cats, and a second-cat feature that
    /// looks broken on a default config.
    ///
    /// Only on the transition from one cat to two. Once the second cat is in the config,
    /// its popup is the user's to set — including to the same coat as the first, if that
    /// is genuinely what they want.
    private func chooseCoatForANewSecondCat() {
        guard secondCatCheck.state == .on, loadedPets.count < 2 else { return }
        let taken = colorPopup.selectedItem?.representedObject as? String ?? CatPalette.default.id
        let coat = Self.coatUnlike(taken)
        guard let index = secondColorPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == coat
        }) else { return }
        secondColorPopup.selectItem(at: index)
    }

    @objc private func resetToDefaults() {
        // [M11] Resets what this window controls, and nothing else. `birthday` and
        // `dedication` have no control here and no way back except hand-editing JSON, so
        // "Reset to Defaults" restores the defaults rather than deleting the gift.
        var reset = PetConfig.default
        reset.birthday = settingsDelegate?.currentConfig.birthday
        reset.dedication = settingsDelegate?.currentConfig.dedication
        settingsDelegate?.settingsDidChange(reset)
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

    /// The coats currently in the second cat's popup, and whether it is usable. Exposed
    /// for `--settings-test` for the same reason `offeredCoatIDs` is.
    var secondCoatIDs: [String] {
        secondColorPopup.itemArray.compactMap { $0.representedObject as? String }
    }
    var secondCoatPopupIsEnabled: Bool { secondColorPopup.isEnabled }

    func simulate(speed: Double? = nil, scale: Int? = nil, screen: String?? = nil,
                  menuBarIcon: Bool? = nil, color: String? = nil, userName: String? = nil,
                  launchAtLogin: Bool? = nil, secondCat: Bool? = nil,
                  secondColor: String? = nil, kisses: Bool? = nil) {
        if let userName { nameField.stringValue = userName }
        if let speed { speedSlider.doubleValue = speed }
        if let scale { scalePopup.selectItem(withTag: scale) }
        if let screen {
            let index = screenPopup.itemArray.firstIndex { ($0.representedObject as? String) == screen }
            screenPopup.selectItem(at: index ?? 0)
        }
        if let menuBarIcon { menuBarCheck.state = menuBarIcon ? .on : .off }
        if let launchAtLogin { loginCheck.state = launchAtLogin ? .on : .off }
        if let kisses { kissCheck.state = kisses ? .on : .off }
        if let color {
            let index = colorPopup.itemArray.firstIndex { ($0.representedObject as? String) == color }
            colorPopup.selectItem(at: index ?? 0)
        }
        if let secondCat { secondCatCheck.state = secondCat ? .on : .off }
        if let secondColor {
            let index = secondColorPopup.itemArray.firstIndex {
                ($0.representedObject as? String) == secondColor
            }
            secondColorPopup.selectItem(at: index ?? 0)
        }
        controlChanged()
    }

    func simulateReset() { resetToDefaults() }
}
