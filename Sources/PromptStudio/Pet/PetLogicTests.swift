// Focused Pet state and preference tests.
#if PET_LOGIC_TESTS
import XCTest

final class PetLogicTests: XCTestCase {
    func testCaptureAndCancelTransitions() {
        var machine = PetStateMachine()
        XCTAssertEqual(machine.transition(.captureRequested), .asking)
        XCTAssertEqual(machine.transition(.cancel), .cancelled)
        XCTAssertEqual(machine.transition(.reset), .idle)
    }

    func testHiddenCaptureDoesNotAsk() {
        var machine = PetStateMachine(state: .hidden)
        XCTAssertEqual(machine.transition(.captureRequested), .hidden)
    }

    func testDefaultPreferencesAreConservative() {
        let preferences = PetPreferences.defaults
        XCTAssertTrue(preferences.showOnLaunch)
        XCTAssertTrue(preferences.captureEnabled)
        XCTAssertFalse(preferences.soundEnabled)
        XCTAssertEqual(preferences.defaultFolderID, "folder-capture-inbox")
    }

    func testSnapOriginClampsAndSnapsToNearestEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let origin = PetGeometry.snappedOrigin(
            proposed: CGPoint(x: 220, y: 210),
            panelSize: CGSize(width: 84, height: 84),
            visibleFrame: screen,
            inset: 16
        )
        XCTAssertEqual(origin.x, 16, accuracy: 0.001)
        XCTAssertEqual(origin.y, 210, accuracy: 0.001)
    }
}
#endif
