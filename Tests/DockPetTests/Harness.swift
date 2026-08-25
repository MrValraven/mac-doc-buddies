//
//  Harness.swift — the minimal assertion machinery shared by the test files.
//
//  SPEC §2 [M1]: this package cannot use XCTest (no Xcode on this machine), so the tests
//  are an executable. This file is the entire framework.
//

import Foundation
import CoreGraphics

enum Harness {
    static var failures = 0
    static var checks = 0

    static func section(_ title: String) { print("\n\(title)") }

    static func check(_ passed: Bool, _ what: String,
                      detail: @autoclosure () -> String = "",
                      file: String = #fileID, line: UInt = #line) {
        checks += 1
        if passed {
            print("  ok    \(what)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL  \(what)\(d.isEmpty ? "" : " — \(d)")  (\(file):\(line))")
        }
    }

    static func eq(_ a: CGFloat, _ b: CGFloat, _ what: String,
                   file: String = #fileID, line: UInt = #line) {
        check(abs(a - b) < 0.001, what, detail: "expected \(b), got \(a)", file: file, line: line)
    }

    static func eq(_ a: CGRect, _ b: CGRect, _ what: String,
                   file: String = #fileID, line: UInt = #line) {
        let same = abs(a.origin.x - b.origin.x) < 0.001 && abs(a.origin.y - b.origin.y) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
        check(same, what, detail: "expected \(b), got \(a)", file: file, line: line)
    }

    static func eq<T: Equatable>(_ a: T?, _ b: T?, _ what: String,
                                 file: String = #fileID, line: UInt = #line) {
        check(a == b, what,
              detail: "expected \(String(describing: b)), got \(String(describing: a))",
              file: file, line: line)
    }

    /// Abandon the run — used when a precondition fails and later assertions would only
    /// produce noise.
    static func bail(_ why: String, file: String = #fileID, line: UInt = #line) -> Never {
        failures += 1
        print("  FAIL  \(why)  (\(file):\(line))")
        finish()
    }

    static func finish() -> Never {
        print("")
        if failures > 0 {
            print("\(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("all \(checks) checks passed")
        exit(0)
    }
}

// Unqualified spellings, so the test files read as assertions rather than as calls.
func section(_ t: String) { Harness.section(t) }
func check(_ p: Bool, _ w: String, detail: @autoclosure () -> String = "",
           file: String = #fileID, line: UInt = #line) {
    Harness.check(p, w, detail: detail(), file: file, line: line)
}
func eq(_ a: CGFloat, _ b: CGFloat, _ w: String, file: String = #fileID, line: UInt = #line) {
    Harness.eq(a, b, w, file: file, line: line)
}
func eq(_ a: CGRect, _ b: CGRect, _ w: String, file: String = #fileID, line: UInt = #line) {
    Harness.eq(a, b, w, file: file, line: line)
}
func eq<T: Equatable>(_ a: T?, _ b: T?, _ w: String, file: String = #fileID, line: UInt = #line) {
    Harness.eq(a, b, w, file: file, line: line)
}
