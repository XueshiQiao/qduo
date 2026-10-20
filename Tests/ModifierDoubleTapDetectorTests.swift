import XCTest

/// Timestamps fed straight into `ModifierDoubleTapDetector`. The window is 0.3s
/// unless a test says otherwise, measured from the first key-down to the second.
final class ModifierDoubleTapDetectorTests: XCTestCase {

    private func assertTap(_ detector: inout ModifierDoubleTapDetector,
                           _ held: Set<ModifierKey>,
                           at time: TimeInterval,
                           fires expected: ModifierKey?,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        XCTAssertEqual(detector.flagsChanged(held: held, time: time), expected,
                       "held \(held) at \(time)", file: file, line: line)
    }

    /// ⌘ down, up, down inside the window fires once. The next press does not.
    func testSecondPressWithinTheWindowFiresOnce() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        assertTap(&detector, [], at: 0.08, fires: nil)
        assertTap(&detector, [.command], at: 0.15, fires: .command)
        // Still down after the fire. Release, then press again: the fire
        // consumed the tap, so this press is the start of a new one.
        assertTap(&detector, [], at: 0.18, fires: nil)
        assertTap(&detector, [.command], at: 0.20, fires: nil)
    }

    /// A second press at 0.31 is too late. It becomes the new first press, so
    /// the one at 0.40 fires.
    func testSecondPressPastTheWindowStartsANewTap() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        assertTap(&detector, [], at: 0.08, fires: nil)
        assertTap(&detector, [.command], at: 0.31, fires: nil)
        assertTap(&detector, [], at: 0.35, fires: nil)
        assertTap(&detector, [.command], at: 0.40, fires: .command)
    }

    /// The second press landing exactly on the window still fires (`<=`).
    func testSecondPressOnTheWindowBoundaryFires() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0, fires: nil)
        assertTap(&detector, [], at: 0.1, fires: nil)
        assertTap(&detector, [.command], at: 0.3, fires: .command)
    }

    /// ⌘ down, then ⇧ down while ⌘ is still held, clears the tap. A command
    /// press right after must not fire, and a shift press must not either.
    /// A normal double tap after that still fires.
    func testTwoModifiersHeldTogetherClearsThePendingTap() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        assertTap(&detector, [.command, .shift], at: 0.05, fires: nil)
        assertTap(&detector, [], at: 0.10, fires: nil)
        // Would fire if the chord had left ⌘ armed.
        assertTap(&detector, [.command], at: 0.20, fires: nil)
        assertTap(&detector, [], at: 0.25, fires: nil)
        assertTap(&detector, [.command], at: 0.30, fires: .command)

        var shiftArmed = ModifierDoubleTapDetector()
        assertTap(&shiftArmed, [.command], at: 0.00, fires: nil)
        assertTap(&shiftArmed, [.command, .shift], at: 0.05, fires: nil)
        assertTap(&shiftArmed, [], at: 0.10, fires: nil)
        // Would fire if the chord had been retargeted onto ⇧.
        assertTap(&shiftArmed, [.shift], at: 0.15, fires: nil)
    }

    /// ⌘ down, C, ⌘ up, ⌘ down, V. The letter cancels it. Never fires.
    func testAKeyBetweenThePressesNeverFires() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        detector.otherKey(time: 0.04)                 // C
        assertTap(&detector, [], at: 0.08, fires: nil)
        assertTap(&detector, [.command], at: 0.12, fires: nil)
        detector.otherKey(time: 0.16)                 // V
        assertTap(&detector, [], at: 0.20, fires: nil)
        assertTap(&detector, [.command], at: 0.24, fires: nil)
    }

    func testMouseDownOrScrollBetweenThePressesNeverFires() {
        var mouse = ModifierDoubleTapDetector()
        assertTap(&mouse, [.command], at: 0.00, fires: nil)
        mouse.mouseDown(time: 0.04)
        assertTap(&mouse, [], at: 0.08, fires: nil)
        assertTap(&mouse, [.command], at: 0.12, fires: nil)

        var scroll = ModifierDoubleTapDetector()
        assertTap(&scroll, [.command], at: 0.00, fires: nil)
        scroll.scroll(time: 0.04)
        assertTap(&scroll, [], at: 0.08, fires: nil)
        assertTap(&scroll, [.command], at: 0.12, fires: nil)
    }

    /// Left ⌘ down, right ⌘ down, left up, right up. The set stays `{command}`
    /// until both are up, so none of those four is a second press. A normal
    /// double tap afterwards still fires. It starts past the window: the first
    /// press is still pending once both sides are up, and a press inside the
    /// window would be that tap's second press.
    func testLeftAndRightOfTheSameModifierAreOneKey() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)   // left down
        assertTap(&detector, [.command], at: 0.05, fires: nil)   // right down
        assertTap(&detector, [.command], at: 0.10, fires: nil)   // left up
        assertTap(&detector, [], at: 0.15, fires: nil)           // right up

        assertTap(&detector, [.command], at: 0.50, fires: nil)
        assertTap(&detector, [], at: 0.55, fires: nil)
        assertTap(&detector, [.command], at: 0.60, fires: .command)
    }

    /// Held for a second, released, pressed at 1.1. The window is from the
    /// first press, not from the release, so this does not fire.
    func testALongHoldDoesNotFire() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.0, fires: nil)
        assertTap(&detector, [], at: 1.0, fires: nil)
        assertTap(&detector, [.command], at: 1.1, fires: nil)
    }

    /// Fn and Caps Lock are delivered to the detector as `otherKey` (the
    /// monitor translates those `.flagsChanged` events). Either one in between
    /// cancels the tap.
    func testOtherKeyBetweenThePressesNeverFires() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        detector.otherKey(time: 0.04)
        assertTap(&detector, [], at: 0.08, fires: nil)
        assertTap(&detector, [.command], at: 0.12, fires: nil)
    }

    /// Only defensive: an event with the same timestamp is processed once. A
    /// second call that says the key is already up must not count as the
    /// release — otherwise the press at 0.10 would complete the tap. The global
    /// monitor and the local monitor do not both deliver one event.
    func testADuplicateTimestampIsIgnored() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        assertTap(&detector, [], at: 0.00, fires: nil)
        assertTap(&detector, [.command], at: 0.10, fires: nil)
        assertTap(&detector, [], at: 0.15, fires: nil)
        assertTap(&detector, [.command], at: 0.20, fires: .command)
    }

    func testCustomWindow() {
        var inside = ModifierDoubleTapDetector(window: 0.5)
        assertTap(&inside, [.command], at: 0, fires: nil)
        assertTap(&inside, [], at: 0.1, fires: nil)
        assertTap(&inside, [.command], at: 0.5, fires: .command)

        var outside = ModifierDoubleTapDetector(window: 0.5)
        assertTap(&outside, [.command], at: 0, fires: nil)
        assertTap(&outside, [], at: 0.1, fires: nil)
        assertTap(&outside, [.command], at: 0.51, fires: nil)
    }

    /// `reset(held:)` is what the monitor does when it starts listening. A key
    /// that is already down is not a press, and a tap that was in progress is
    /// forgotten.
    func testResetForgetsThePendingTap() {
        var detector = ModifierDoubleTapDetector()
        assertTap(&detector, [.command], at: 0.00, fires: nil)
        detector.reset(held: [.command])
        assertTap(&detector, [], at: 0.10, fires: nil)
        assertTap(&detector, [.command], at: 0.20, fires: nil)
        assertTap(&detector, [], at: 0.25, fires: nil)
        assertTap(&detector, [.command], at: 0.30, fires: .command)
    }

    func testEachModifierFires() {
        for key in ModifierKey.allCases {
            var detector = ModifierDoubleTapDetector()
            assertTap(&detector, [key], at: 0, fires: nil)
            assertTap(&detector, [], at: 0.05, fires: nil)
            assertTap(&detector, [key], at: 0.10, fires: key)
        }
    }
}
