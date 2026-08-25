// swift-tools-version:5.9
import PackageDescription

// Swift 5 language mode on purpose: nothing here needs strict concurrency, and SPEC §1
// asks for a boring toolchain. Resources are copied into the .app by bundle.sh, not by
// SwiftPM, so this package declares no resource rules.
//
// GeometryTests is an .executableTarget rather than a .testTarget: this machine has
// Command Line Tools without Xcode, so XCTest and swift-testing are both unavailable.
// See the [M1] amendment in SPEC §2. Run it with `swift run GeometryTests`.
let package = Package(
    name: "DockPet",
    platforms: [
        .macOS(.v13)          // SPEC §1: deployment target stays at 13.0
    ],
    targets: [
        // Pure logic. Imports CoreGraphics only — never AppKit — which is what makes
        // SPEC §5's "no AppKit in Behavior.swift" a compiler-enforced rule.
        .target(
            name: "DockPetCore",
            path: "Sources/DockPetCore"
        ),
        .executableTarget(
            name: "DockPet",
            dependencies: ["DockPetCore"],
            path: "Sources/DockPet"
        ),
        .executableTarget(
            name: "GeometryTests",
            dependencies: ["DockPetCore"],
            path: "Tests/DockPetTests"
        ),
    ]
)
