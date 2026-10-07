import AppKit

/// Drag-to-select: a left-mouse-down, several drag events, then mouse-up. We
/// require a minimum number of drag events so an ordinary click (down → up with
/// no drags) doesn't fire.
final class DragSelectGesture: SelectionGesture {
    let id = "drag-select"
    private let dragThreshold: Int
    private var dragCount = 0

    init(dragThreshold: Int = 3) { self.dragThreshold = dragThreshold }

    func consume(_ event: InputEvent) -> Bool {
        switch event {
        case .mouseDown:
            dragCount = 0
        case .mouseDragged:
            dragCount += 1
        case .mouseUp:
            let fired = dragCount >= dragThreshold
            dragCount = 0
            return fired
        default:
            dragCount = 0
        }
        return false
    }
}

/// Double- (or triple-) click to select a word/line. `NSEvent` tracks the click
/// count for us.
///
/// Completes when the button of that click is RELEASED, not when it goes down
/// (issue #13): the second press can be held and dragged to grow the selection
/// word by word, and a popup opened on the press sat on top of the text still
/// being selected. The press is remembered here rather than read off the
/// mouse-up, so nothing depends on what click count a mouse-up carries after a
/// drag.
final class DoubleClickGesture: SelectionGesture {
    let id = "double-click"
    /// The button that is down now went down as a 2nd (or later) click.
    private var armed = false

    func consume(_ event: InputEvent) -> Bool {
        switch event {
        case let .mouseDown(nsEvent):
            armed = nsEvent.clickCount >= 2
        case .mouseUp:
            let fired = armed
            armed = false
            return fired
        default:
            break
        }
        return false
    }
}
