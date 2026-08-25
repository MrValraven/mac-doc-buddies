//
//  main.swift — DockPet entry point
//
//  SPEC §1: explicit NSApplication + NSApplicationDelegate, no SwiftUI app lifecycle.
//

import AppKit

// Line-buffer stdout so `--verbose` output appears immediately when the binary is run
// from a terminal or piped, rather than being held in a 4 KB block buffer.
setvbuf(stdout, nil, _IOLBF, 0)

let options = LaunchOptions(arguments: CommandLine.arguments)

let app = NSApplication.shared

// SPEC §2: belt-and-braces alongside LSUIElement in Info.plist. Set before the delegate
// runs so the app never flashes a Dock icon, even for a frame.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
