import XCTest
import AppKit

/// The ⌘C-first read for listed apps (Chrome): whose text is used, and when ⌘C
/// is pressed at all.
final class CopyFirstStrategyTests: XCTestCase {

    private final class FakeAccessibility: SelectionStrategy {
        let id = SelectionStrategyID.accessibility
        var result: SelectionResult?
        init(_ text: String?) {
            result = text.map { SelectionResult(text: $0, via: .accessibility, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)) }
        }
        func selectedText(_ context: SelectionContext) async throws -> SelectionResult? { result }
    }

    private struct Boom: Error {}

    private func context(listed: Bool = true, allowsCopy: Bool = true) -> SelectionContext {
        SelectionContext(frontmostApp: nil, mouseLocation: .zero, clipboardChangeCountAtGestureStart: 0,
                         resolvesLinks: false, allowsSimulatedCopy: allowsCopy, prefersSimulatedCopy: listed)
    }

    /// Runs the strategy; returns its result and how often ⌘C was "pressed".
    private func run(direct: String?, copied: String?, throwing: Error? = nil) async throws -> (SelectionResult?, Int) {
        var presses = 0
        let strategy = CopyFirstStrategy(accessibility: FakeAccessibility(direct)) { _ in
            presses += 1
            if let throwing { throw throwing }
            return copied.map { SelectionResult(text: $0, via: .clipboardCopy, bounds: nil) }
        }
        let result = try await strategy.selectedText(context())
        return (result, presses)
    }

    func testOnlyForListedAppsWithTheCopySwitchOn() {
        let strategy = CopyFirstStrategy(accessibility: FakeAccessibility("a")) { _ in nil }
        XCTAssertTrue(strategy.canHandle(context()))
        XCTAssertFalse(strategy.canHandle(context(listed: false)))
        XCTAssertFalse(strategy.canHandle(context(allowsCopy: false)))
    }

    func testCopiedTextWinsAndKeepsWhatAccessibilityKnows() async throws {
        let (result, presses) = try await run(direct: "one two", copied: "one\ntwo")
        XCTAssertEqual(result?.text, "one\ntwo")
        XCTAssertEqual(result?.via, .clipboardCopy)
        XCTAssertEqual(result?.bounds, CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(presses, 1)
    }

    func testNothingReadDirectlyMeansNoCopyAndNoResult() async throws {
        for direct in [nil, "", " \n"] {
            let (result, presses) = try await run(direct: direct, copied: "stale")
            XCTAssertNil(result)
            XCTAssertEqual(presses, 0)
        }
    }

    func testDirectTextIsUsedWhenTheCopyBringsNothing() async throws {
        for copied in [nil, "", "  "] {
            let (result, _) = try await run(direct: "one two", copied: copied)
            XCTAssertEqual(result?.text, "one two")
            XCTAssertEqual(result?.via, .accessibility)
        }
    }

    func testDirectTextIsUsedWhenTheCopyFails() async throws {
        let (result, _) = try await run(direct: "one two", copied: nil, throwing: Boom())
        XCTAssertEqual(result?.text, "one two")
    }

    func testCancellationIsNotSwallowed() async {
        do {
            _ = try await run(direct: "one two", copied: nil, throwing: CancellationError())
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
