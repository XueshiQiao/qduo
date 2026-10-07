import XCTest
import AppKit

/// When the selection gestures call a selection finished. The popup opens on
/// that, so a gesture that finishes while the mouse button is still down puts the
/// popup on top of text the user is still selecting (issue #13).
final class SelectionGestureTests: XCTestCase {

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }
    private func down(_ clicks: Int) -> InputEvent { .mouseDown(mouse(.leftMouseDown, clicks: clicks)) }
    /// `clicks` defaults to 0: the gesture must not depend on a mouse-up's count.
    private func up(_ clicks: Int = 0) -> InputEvent { .mouseUp(mouse(.leftMouseUp, clicks: clicks)) }
    private var drag: InputEvent { .mouseDragged(mouse(.leftMouseDragged)) }

    /// Feed the events in order; the indexes of the ones that completed the gesture.
    private func fired(_ gesture: SelectionGesture, _ events: [InputEvent]) -> [Int] {
        events.enumerated().filter { gesture.consume($0.element) }.map(\.offset)
    }

    func testSingleClickDoesNotFire() {
        XCTAssertEqual(fired(DoubleClickGesture(), [down(1), up()]), [])
    }

    func testDoubleClickFiresOnTheSecondRelease() {
        XCTAssertEqual(fired(DoubleClickGesture(), [down(1), up(), down(2), up()]), [3])
    }

    func testDoubleClickHeldAndDraggedFiresOnlyOnRelease() {
        let events = [down(1), up(), down(2), drag, drag, drag, drag, up()]
        XCTAssertEqual(fired(DoubleClickGesture(), events), [7])
    }

    func testTripleClickFiresOnTheSecondAndThirdRelease() {
        let events = [down(1), up(), down(2), up(), down(3), up()]
        XCTAssertEqual(fired(DoubleClickGesture(), events), [3, 5])
    }

    func testAClickAfterADoubleClickDoesNotFire() {
        let events = [down(1), up(), down(2), up(), down(1), up()]
        XCTAssertEqual(fired(DoubleClickGesture(), events), [3])
    }

    /// A release that never reached us must not leave the next click armed.
    func testALostReleaseDoesNotArmTheNextClick() {
        XCTAssertEqual(fired(DoubleClickGesture(), [down(1), up(), down(2), down(1), up()]), [])
    }

    func testDragSelectFiresOnRelease() {
        XCTAssertEqual(fired(DragSelectGesture(), [down(1), drag, drag, drag, up()]), [4])
        XCTAssertEqual(fired(DragSelectGesture(), [down(1), drag, up()]), [])
    }
}
