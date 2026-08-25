//
//  SpriteTests.swift — assertions for DockPetCore.SpriteMetadata and FrameSequencer
//

import Foundation
import CoreGraphics
import DockPetCore

enum SpriteTests {

    /// The sidecar exactly as SPEC §5 writes it.
    private static let sidecarJSON = #"{"frameWidth":32,"frameHeight":32,"frameCount":8,"fps":10}"#

    private static let standard = SpriteMetadata(frameWidth: 32, frameHeight: 32, frameCount: 8, fps: 10)

    static func run() {

        section("sprite metadata: sidecar decoding")

        do {
            let decoded = try JSONDecoder().decode(SpriteMetadata.self,
                                                   from: Data(sidecarJSON.utf8))
            check(decoded == standard, "the sidecar from SPEC §5 decodes to the expected values",
                  detail: "got \(decoded)")
        } catch {
            check(false, "the sidecar from SPEC §5 decodes", detail: "\(error)")
        }

        // Round-tripping matters: the placeholder generator writes this file itself.
        do {
            let data = try JSONEncoder().encode(standard)
            let back = try JSONDecoder().decode(SpriteMetadata.self, from: data)
            check(back == standard, "metadata survives an encode/decode round trip")
        } catch {
            check(false, "metadata round trip", detail: "\(error)")
        }

        section("sprite metadata: validation")

        check((try? standard.validate()) != nil, "a well-formed sheet validates")

        for (field, meta) in [
            ("frameWidth",  SpriteMetadata(frameWidth: 0, frameHeight: 32, frameCount: 8, fps: 10)),
            ("frameHeight", SpriteMetadata(frameWidth: 32, frameHeight: 0, frameCount: 8, fps: 10)),
            ("frameCount",  SpriteMetadata(frameWidth: 32, frameHeight: 32, frameCount: 0, fps: 10)),
            ("fps",         SpriteMetadata(frameWidth: 32, frameHeight: 32, frameCount: 8, fps: 0)),
        ] {
            var threw = false
            do { try meta.validate() } catch { threw = true }
            check(threw, "a sheet with \(field) = 0 is rejected")
        }

        var negativeThrew = false
        do {
            try SpriteMetadata(frameWidth: -32, frameHeight: 32, frameCount: 8, fps: 10).validate()
        } catch { negativeThrew = true }
        check(negativeThrew, "a negative frameWidth is rejected")

        section("sprite metadata: sheet dimensions must agree with the sidecar")

        eq(CGFloat(standard.sheetWidthPx), 256, "8 frames of 32 px make a 256 px sheet")

        check((try? standard.validate(againstSheetWidthPx: 256, heightPx: 32)) != nil,
              "a 256x32 sheet matches the sidecar")

        var widthThrew: SpriteSheetError?
        do { try standard.validate(againstSheetWidthPx: 200, heightPx: 32) }
        catch let e as SpriteSheetError { widthThrew = e } catch {}
        check(widthThrew == .sheetWidthMismatch(expectedPx: 256, actualPx: 200),
              "a too-narrow sheet is rejected with the measurements in the error",
              detail: "\(String(describing: widthThrew))")

        var heightThrew: SpriteSheetError?
        do { try standard.validate(againstSheetWidthPx: 256, heightPx: 64) }
        catch let e as SpriteSheetError { heightThrew = e } catch {}
        check(heightThrew == .sheetHeightMismatch(expectedPx: 32, actualPx: 64),
              "a too-tall sheet is rejected",
              detail: "\(String(describing: heightThrew))")

        // The stationary poses are single-frame sheets, so the sidecar arithmetic has to
        // hold at frameCount 1: the sheet is exactly one frame wide, not a degenerate case.
        let singlePose = SpriteMetadata(frameWidth: 32, frameHeight: 32, frameCount: 1, fps: 10)
        eq(CGFloat(singlePose.sheetWidthPx), 32, "a one-frame sheet is one frame wide")
        check((try? singlePose.validate(againstSheetWidthPx: 32, heightPx: 32)) != nil,
              "a 32x32 sheet matches a one-frame sidecar")

        section("sprite metadata: frame source rectangles")

        eq(standard.sourceRectPx(frame: 0), CGRect(x: 0, y: 0, width: 32, height: 32),
           "frame 0 starts at x=0")
        eq(standard.sourceRectPx(frame: 1), CGRect(x: 32, y: 0, width: 32, height: 32),
           "frames run left to right")
        eq(standard.sourceRectPx(frame: 7), CGRect(x: 224, y: 0, width: 32, height: 32),
           "the last frame ends exactly at the sheet's right edge")
        eq(standard.sourceRectPx(frame: 8), standard.sourceRectPx(frame: 0),
           "an out-of-range index wraps rather than reading past the sheet")
        eq(standard.sourceRectPx(frame: -1), standard.sourceRectPx(frame: 7),
           "a negative index wraps too")

        // Non-square frames must not silently transpose.
        let wide = SpriteMetadata(frameWidth: 48, frameHeight: 24, frameCount: 3, fps: 12)
        eq(wide.sourceRectPx(frame: 2), CGRect(x: 96, y: 0, width: 48, height: 24),
           "non-square frames slice on width, not height")

        section("sprite scaling (SPEC §5, §8 trap 4)")

        eq(standard.pointSize(scale: 1).width, 32, "1x is 32 pt wide")
        eq(standard.pointSize(scale: 2).width, 64, "2x is 64 pt wide")
        eq(standard.pointSize(scale: 3).height, 96, "3x is 96 pt tall")

        // The measured displays: built-in at 2.0, external at 1.0 (PROBE.md Run 1).
        eq(standard.devicePixelsPerArtPixel(scale: 2, backingScaleFactor: 2.0), 4,
           "2x sprite on the 2x built-in display is 4 device px per art px")
        eq(standard.devicePixelsPerArtPixel(scale: 2, backingScaleFactor: 1.0), 2,
           "2x sprite on the 1x external display is 2 device px per art px")

        check(standard.isCrisp(scale: 2, backingScaleFactor: 2.0), "2x at 2x backing is crisp")
        check(standard.isCrisp(scale: 2, backingScaleFactor: 1.0), "2x at 1x backing is crisp")
        check(standard.isCrisp(scale: 3, backingScaleFactor: 2.0), "3x at 2x backing is crisp")
        check(!standard.isCrisp(scale: 0, backingScaleFactor: 2.0), "0x is not a usable scale")
        check(!standard.isCrisp(scale: -1, backingScaleFactor: 2.0), "a negative scale is rejected")
        check(!standard.isCrisp(scale: 1, backingScaleFactor: 1.25),
              "a fractional backing scale is flagged, not silently blurred")

        section("frame sequencer")

        var seq = FrameSequencer(frameCount: 8, fps: 10)
        eq(CGFloat(seq.loopDuration), 0.8, "8 frames at 10 fps loop in 0.8 s")
        check(seq.index == 0, "starts on frame 0")

        seq.advance(by: 0.05)
        check(seq.index == 0, "half a frame in, still on frame 0")
        seq.advance(by: 0.05)
        check(seq.index == 1, "a full frame in, on frame 1")

        // Advancing at the app's 12 fps must still yield the sheet's own 10 fps.
        //
        // Sampled mid-frame on purpose. Seven ticks is 0.5833 s, comfortably inside
        // frame 5's window of [0.5, 0.6). Testing exactly on a boundary would be testing
        // floating-point accumulation rather than the sequencer: six ticks of 1.0/12.0
        // sum to 0.49999999999999994, which is legitimately still frame 4.
        seq = FrameSequencer(frameCount: 8, fps: 10)
        for _ in 0..<7 { seq.advance(by: 1.0 / 12.0) }   // 0.583 s
        check(seq.index == 5, "0.58 s at 10 fps is frame 5, regardless of the 12 fps tick",
              detail: "got \(seq.index)")

        // The app's tick rate must not change which frame you land on.
        var byTicks = FrameSequencer(frameCount: 8, fps: 10)
        var byOneStep = FrameSequencer(frameCount: 8, fps: 10)
        for _ in 0..<7 { byTicks.advance(by: 1.0 / 12.0) }
        byOneStep.advance(by: 7.0 / 12.0)
        check(byTicks.index == byOneStep.index,
              "ticking and one big step agree on the frame",
              detail: "\(byTicks.index) vs \(byOneStep.index)")

        seq = FrameSequencer(frameCount: 8, fps: 10)
        seq.advance(by: 0.8)
        check(seq.index == 0, "the sheet loops back to frame 0 after one full cycle")

        seq = FrameSequencer(frameCount: 8, fps: 10)
        seq.advance(by: 0.85)
        check(seq.index == 0, "and keeps counting from the start of the new cycle")

        // A day of running must not drift or overflow.
        seq = FrameSequencer(frameCount: 8, fps: 10)
        for _ in 0..<(12 * 60 * 60) { seq.advance(by: 1.0 / 12.0) }   // one hour at 12 fps
        check(seq.index >= 0 && seq.index < 8, "index stays in range after an hour of ticks",
              detail: "got \(seq.index)")

        seq = FrameSequencer(frameCount: 8, fps: 10)
        seq.advance(by: 0.3)
        seq.reset()
        check(seq.index == 0, "reset returns to the first frame")

        seq = FrameSequencer(frameCount: 8, fps: 10)
        seq.advance(by: -1)
        check(seq.index == 0, "a negative dt does not rewind the sheet")

        section("frame sequencer: degenerate sheets")

        var single = FrameSequencer(frameCount: 1, fps: 10)
        single.advance(by: 5)
        check(single.index == 0, "a one-frame sheet stays on frame 0")

        var zero = FrameSequencer(frameCount: 0, fps: 10)
        zero.advance(by: 1)
        check(zero.index == 0, "a zero-frame sheet does not divide by zero")

        var noFPS = FrameSequencer(frameCount: 8, fps: 0)
        noFPS.advance(by: 1)
        check(noFPS.index >= 0 && noFPS.index < 8, "a zero-fps sheet does not divide by zero")
    }
}
