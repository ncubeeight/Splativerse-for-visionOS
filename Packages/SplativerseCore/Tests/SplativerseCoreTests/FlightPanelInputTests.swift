import XCTest
import simd
@testable import SplativerseCore

final class FlightPanelInputTests: XCTestCase {
    let panel = translation(SIMD3<Float>(0.4,1.1,-0.3)) * rotationY(0.7)
    func event(_ id: UUID, _ phase: FlightPanelEvent.Phase, target: FlightPanelAction, direct: Bool = false) -> FlightPanelEvent {
        let p = panel * SIMD4(FlightController.buttonCenter(target),1)
        let point = SIMD3(p.x,p.y,p.z)
        if direct { return FlightPanelEvent(id: id,phase: phase,point: point) }
        let head = SIMD3<Float>(0,1.65,0)
        return FlightPanelEvent(id: id,phase: phase,origin: head,direction: simd_normalize(point-head))
    }
    func testLookAndPinchEachRaisedButtonAtRotatedPanel() {
        for action in FlightPanelAction.allCases {
            var input = FlightPanelInput(); let id = UUID()
            XCTAssertNil(input.update(event(id,.active,target: action),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
            XCTAssertEqual(input.pressed,[action])
            XCTAssertNil(input.update(event(id,.active,target: action),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
            XCTAssertEqual(input.update(event(id,.ended,target: action),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true),action)
            XCTAssertTrue(input.pressed.isEmpty)
            XCTAssertNil(input.update(event(id,.ended,target: action),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
        }
    }
    func testDirectTouchUsesSameActionsWithoutASelectionRay() {
        for action in FlightPanelAction.allCases {
            var input = FlightPanelInput(); let id = UUID()
            _ = input.update(event(id,.active,target: action,direct: true),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
            XCTAssertEqual(input.update(event(id,.ended,target: action,direct: true),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true),action)
        }
    }
    func testCancelAndDragOffNeverCommitOrSwitchTarget() {
        for cancelled in [false,true] {
            var input = FlightPanelInput(); let id = UUID()
            _ = input.update(event(id,.active,target: .next),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
            let changed = event(id,cancelled ? .cancelled : .active,target: .previous)
            XCTAssertNil(input.update(changed,panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
            XCTAssertTrue(input.pressed.isEmpty)
            XCTAssertNil(input.update(event(id,.ended,target: .previous),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
        }
    }
    func testPinchMustBeginOverButton() {
        var input = FlightPanelInput(); let id = UUID()
        _ = input.update(FlightPanelEvent(id: id,phase: .active,point: .zero),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
        _ = input.update(event(id,.active,target: .next),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
        XCTAssertNil(input.update(event(id,.ended,target: .next),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
    }
    func testLoadingAndEndpointsDisableOnlyScanNavigation() {
        for action in FlightPanelAction.allCases {
            var input = FlightPanelInput(); let id = UUID()
            _ = input.update(event(id,.active,target: action),panel: panel,enabled: true,canGoPrevious: false,canGoNext: false)
            let result = input.update(event(id,.ended,target: action),panel: panel,enabled: true,canGoPrevious: false,canGoNext: false)
            XCTAssertEqual(result,action == .next || action == .previous ? nil : action)
        }
    }
    func testHidingPanelOrLosingReadinessCancelsPress() {
        var input = FlightPanelInput(); let id = UUID()
        _ = input.update(event(id,.active,target: .next),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
        XCTAssertNil(input.update(event(id,.ended,target: .next),panel: panel,enabled: true,canGoPrevious: true,canGoNext: false))
        _ = input.update(event(id,.active,target: .menu),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
        XCTAssertNil(input.update(event(id,.ended,target: .menu),panel: panel,enabled: false,canGoPrevious: true,canGoNext: true))
        XCTAssertTrue(input.pressed.isEmpty)
    }
    func testInvalidParallelAndBackwardRaysDoNotSelect() {
        for direction in [SIMD3<Float>(0,1,0),SIMD3(1,0,0),SIMD3(.nan,-1,0)] {
            var input = FlightPanelInput(); let id = UUID()
            for phase in [FlightPanelEvent.Phase.active,.ended] {
                let e = FlightPanelEvent(id: id,phase: phase,origin: SIMD3(0,1.65,0),direction: direction)
                XCTAssertNil(input.update(e,panel: panel,enabled: true,canGoPrevious: true,canGoNext: true))
            }
            XCTAssertTrue(input.pressed.isEmpty)
        }
    }
    func testSystemReleaseWithoutFinalPoseUsesCapturedTarget() {
        var input = FlightPanelInput(); let id = UUID()
        _ = input.update(event(id,.active,target: .menu),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true)
        XCTAssertEqual(input.update(FlightPanelEvent(id: id,phase: .ended),panel: panel,enabled: true,canGoPrevious: true,canGoNext: true),.menu)
    }
}
