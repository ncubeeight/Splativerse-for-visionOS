import XCTest
import simd
@testable import SplativerseCore

final class FlightControllerTests: XCTestCase {
    let head = translation(SIMD3<Float>(0,1.65,0))
    let dt: Float = 1/90
    func point(_ c: FlightController, local: SIMD3<Float>) -> SIMD3<Float> {
        let p = c.panelTransform * SIMD4(local,1); return SIMD3(p.x,p.y,p.z)
    }
    func hand(_ p: SIMD3<Float>, side: FlightHand.Side = .right, pinch: Float = 0.015) -> FlightHand {
        FlightHand(side: side,position: p,orientation: simd_quatf(angle: 0,axis: SIMD3(0,1,0)),pinchDistance: pinch)
    }
    @discardableResult func grab(_ c: inout FlightController, placement: Bool = false, side: FlightHand.Side = .right) -> SIMD3<Float> {
        if !c.hasPlacement { c.bringPanelHere(head: head) }
        let p = point(c,local: placement ? FlightController.moveHandleCenter : SIMD3(0,FlightController.leverLength,0))
        _ = c.update(head: head,hands: [hand(p,side: side,pinch: 0.07)],deltaTime: dt,enabled: true)
        let m = c.update(head: head,hands: [hand(p,side: side)],deltaTime: dt,enabled: true)
        XCTAssertEqual(c.isMovingPanel,placement); XCTAssertEqual(c.isHeld,!placement)
        XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0)
        return p
    }
    func settle(_ c: inout FlightController, at p: SIMD3<Float>, head customHead: simd_float4x4? = nil, side: FlightHand.Side = .right) -> FlightMotion {
        var m = FlightMotion()
        for _ in 0..<90 { m = c.update(head: customHead ?? head,hands: [hand(p,side: side)],deltaTime: dt,enabled: true) }
        return m
    }
    func testInitialPlacementAndLookingDown() {
        let p = FlightController.restingHandle(head: head)
        XCTAssertEqual(p.x,0); XCTAssertEqual(p.y,1.36,accuracy: 0.001); XCTAssertEqual(p.z,-0.28,accuracy: 0.001)
        let pitched = head * simd_float4x4(simd_quatf(angle: -.pi/4,axis: SIMD3(1,0,0)))
        XCTAssertEqual(FlightController.restingHandle(head: pitched),p)
    }
    func testPanelDoesNotFollowIdleHeadTurnsOrMovement() {
        var c = FlightController()
        _ = c.update(head: head,hands: [],deltaTime: dt,enabled: true)
        let original = c.panelTransform
        let moved = translation(SIMD3(1,1.2,0.4)) * rotationY(.pi/2)
        for _ in 0..<90 { _ = c.update(head: moved,hands: [],deltaTime: dt,enabled: true) }
        XCTAssertEqual(c.panelTransform,original)
    }
    func testFreshPinchMustStartNearStickOrRail() {
        var c = FlightController(); c.bringPanelHere(head: head)
        let p = point(c,local: SIMD3(0,0.11,0))
        _ = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld)
        _ = c.update(head: head,hands: [hand(p,pinch: 0.07)],deltaTime: dt,enabled: true)
        _ = c.update(head: head,hands: [hand(p+SIMD3(0.3,0,0))],deltaTime: dt,enabled: true)
        _ = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld); XCTAssertFalse(c.isMovingPanel)
        grab(&c)
    }
    func testForwardBackwardAndGradualTurningWithEitherHand() {
        for side in FlightHand.Side.allCases {
            var c = FlightController(); let p = grab(&c,side: side)
            var m = settle(&c,at: p+SIMD3(0.065,0,-0.065),side: side)
            XCTAssertEqual(m.forward,2,accuracy: 0.001); XCTAssertEqual(m.yaw,-.pi/4,accuracy: 0.001)
            m = settle(&c,at: p+SIMD3(-0.065,0,0.065),side: side)
            XCTAssertEqual(m.forward,-2,accuracy: 0.001); XCTAssertEqual(m.yaw,.pi/4,accuracy: 0.001)
            m = settle(&c,at: p+SIMD3(0.03,0,-0.03),side: side)
            XCTAssertGreaterThan(m.forward,0); XCTAssertLessThan(m.forward,1)
            XCTAssertLessThan(m.yaw,0); XCTAssertGreaterThan(m.yaw,-.pi/4)
        }
    }
    func testFlightFollowsCurrentHeadsetDirectionIncludingElevation() {
        var c = FlightController(); let p = grab(&c)
        var m = settle(&c,at: p+SIMD3(0,0,-0.065))
        XCTAssertEqual(m.trackingForward,SIMD3(0,0,-1))
        let lookedRight = head * rotationY(-.pi/2)
        m = settle(&c,at: p+SIMD3(0,0,-0.065),head: lookedRight)
        XCTAssertEqual(m.trackingForward.x,1,accuracy: 0.001); XCTAssertEqual(m.forward,2,accuracy: 0.001)
        let lookedUp = head * simd_float4x4(simd_quatf(angle: .pi/4,axis: SIMD3(1,0,0)))
        m = settle(&c,at: p+SIMD3(0,0,-0.065),head: lookedUp)
        XCTAssertGreaterThan(m.trackingForward.y,0.7)
        var pose = NavigationPose(); pose.begin(at: head)
        pose.fly(m,deltaTime: dt,head: lookedUp)
        XCTAssertGreaterThan(pose.worldFromTracking.columns.3.y,0)
        XCTAssertEqual(pose.worldFromTracking.columns.1,SIMD4(0,1,0,0),"Flight must not add pitch or roll")
    }
    func testNeutralAndReleaseStopWithoutInertia() {
        var c = FlightController(); let p = grab(&c)
        _ = settle(&c,at: p+SIMD3(0.06,0,-0.06))
        var m = c.update(head: head,hands: [hand(p+SIMD3(0.005,0,-0.005))],deltaTime: dt,enabled: true)
        XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0)
        _ = settle(&c,at: p+SIMD3(0.06,0,-0.06))
        let panel = c.panelTransform
        m = c.update(head: head,hands: [hand(p,pinch: 0.07)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld); XCTAssertEqual(c.panelTransform,panel)
        var pose = NavigationPose(); pose.begin(at: head); let before = pose.worldFromTracking
        pose.fly(m,deltaTime: dt,head: head); XCTAssertEqual(pose.worldFromTracking,before)
    }
    func testRailDragTranslatesPanelAndReleaseLocksIt() {
        for side in FlightHand.Side.allCases {
            var c = FlightController(); let p = grab(&c,placement: true,side: side)
            let delta = SIMD3<Float>(0.04,0.08,0.05)
            let m = c.update(head: head,hands: [hand(p+delta,side: side)],deltaTime: dt,enabled: true)
            XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0); XCTAssertFalse(c.isHeld)
            XCTAssertLessThan(simd_distance(point(c,local: FlightController.moveHandleCenter),p+delta),0.001)
            let facing = SIMD2(c.panelTransform.columns.2.x,c.panelTransform.columns.2.z)
            let toward = simd_normalize(SIMD2(head.columns.3.x-c.panelTransform.columns.3.x,head.columns.3.z-c.panelTransform.columns.3.z))
            XCTAssertGreaterThan(simd_dot(facing,toward),0.999)
            XCTAssertEqual(c.panelTransform.columns.1,SIMD4(0,1,0,0))
            let placed = c.panelTransform
            _ = c.update(head: head,hands: [hand(p+delta,side: side,pinch: 0.07)],deltaTime: dt,enabled: true)
            XCTAssertFalse(c.isMovingPanel)
            _ = c.update(head: head * rotationY(.pi/2),hands: [],deltaTime: dt,enabled: true)
            XCTAssertEqual(c.panelTransform,placed)
        }
    }
    func testMovingPanelCannotDriveCameraOrTransferToStick() {
        var c = FlightController(); let p = grab(&c,placement: true,side: .left)
        let stick = point(c,local: SIMD3(0,0.11,0))
        var m = c.update(head: head,hands: [hand(p+SIMD3(0,0,-0.06),side: .left),hand(stick,side: .right)],deltaTime: dt,enabled: true)
        XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0); XCTAssertFalse(c.isHeld)
        m = c.update(head: head,hands: [hand(stick,side: .right)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isMovingPanel); XCTAssertFalse(c.isHeld); XCTAssertEqual(m.forward,0)
        _ = c.update(head: head,hands: [hand(stick,side: .right)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld)
    }
    func testFlightGripCannotAlsoMovePanel() {
        var c = FlightController(); let p = grab(&c,side: .left)
        let before = c.panelTransform, rail = point(c,local: FlightController.moveHandleCenter)
        _ = c.update(head: head,hands: [hand(p,side: .left),hand(rail,side: .right,pinch: 0.07)],deltaTime: dt,enabled: true)
        _ = c.update(head: head,hands: [hand(p,side: .left),hand(rail,side: .right)],deltaTime: dt,enabled: true)
        XCTAssertTrue(c.isHeld); XCTAssertFalse(c.isMovingPanel); XCTAssertEqual(c.panelTransform,before)
    }
    func testTrackingLossAndPausePreserveLastPanelPlacement() {
        for mode in 0..<4 {
            var c = FlightController(); let p = grab(&c,placement: true)
            _ = c.update(head: head,hands: [hand(p+SIMD3(0,0.05,0))],deltaTime: dt,enabled: true)
            let before = c.panelTransform
            let hands = mode == 0 ? [] : [hand(p+SIMD3(0,0.05,0))]
            _ = c.update(head: head,hands: hands,deltaTime: mode == 1 ? 0.3 : dt,enabled: mode != 2)
            if mode == 3 { c.reset() }
            XCTAssertEqual(c.panelTransform,before)
            if mode != 3 { XCTAssertFalse(c.isMovingPanel) }
        }
    }
    func testInvalidOrJumpingDragSamplesDoNotTeleportPanel() {
        for offset in [SIMD3<Float>(.nan,0,0),SIMD3<Float>(1,0,0)] {
            var c = FlightController(); let p = grab(&c,placement: true); let before = c.panelTransform
            _ = c.update(head: head,hands: [hand(p+offset)],deltaTime: dt,enabled: true)
            XCTAssertFalse(c.isMovingPanel); XCTAssertEqual(c.panelTransform,before)
        }
    }
    func testHeightAndDistanceAdjustmentsAndBounds() {
        var c = FlightController(); c.bringPanelHere(head: head)
        let before = c.panelTransform
        c.adjustPanel(height: 0.05,distance: 0,head: head)
        XCTAssertEqual(c.panelTransform.columns.3.y,before.columns.3.y+0.05,accuracy: 0.001)
        c.adjustPanel(height: 0,distance: -0.05,head: head)
        XCTAssertEqual(c.panelTransform.columns.3.z,-0.23,accuracy: 0.001)
        c.adjustPanel(height: 100,distance: -100,head: head)
        XCTAssertEqual(c.panelTransform.columns.3.y,1.5,accuracy: 0.001); XCTAssertEqual(c.panelTransform.columns.3.z,-0.18,accuracy: 0.001)
        c.adjustPanel(height: -100,distance: 100,head: head)
        XCTAssertEqual(c.panelTransform.columns.3.y,0.8,accuracy: 0.001); XCTAssertEqual(c.panelTransform.columns.3.z,-0.85,accuracy: 0.001)
    }
    func testNudgesStopFlightWithoutChangingCamera() {
        var c = FlightController(); let p = grab(&c)
        _ = settle(&c,at: p+SIMD3(0.06,0,-0.06))
        c.adjustPanel(height: 0.05,distance: 0,head: head)
        XCTAssertFalse(c.isHeld)
        let m = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
        XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0)
    }
    func testBringHereRestoresReachAtNewSeatedHeightAndFacing() {
        var c = FlightController(); grab(&c)
        let seated = translation(SIMD3(1,1.1,2)) * rotationY(-.pi/2)
        c.bringPanelHere(head: seated)
        XCTAssertFalse(c.isHeld); XCTAssertFalse(c.isMovingPanel)
        XCTAssertEqual(c.panelTransform.columns.3.y,0.7,accuracy: 0.001)
        XCTAssertEqual(c.panelTransform.columns.3.x,1.28,accuracy: 0.001)
        XCTAssertEqual(c.panelTransform.columns.3.z,2,accuracy: 0.001)
    }
    func testLostFlightGripNeedsFreshPinchAndCannotSwitchHands() {
        var c = FlightController(); let p = grab(&c)
        _ = c.update(head: head,hands: [hand(p,side: .left)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld)
        _ = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld)
    }
    func testHysteresisAndVerticalHandMotionDoNotChangeFlight() {
        var c = FlightController(); let p = grab(&c)
        let m = c.update(head: head,hands: [hand(p+SIMD3(0,0.05,0),pinch: 0.032)],deltaTime: dt,enabled: true)
        XCTAssertTrue(c.isHeld); XCTAssertEqual(m.forward,0); XCTAssertEqual(m.yaw,0)
        _ = c.update(head: head,hands: [hand(p,pinch: 0.041)],deltaTime: dt,enabled: true)
        XCTAssertFalse(c.isHeld)
    }
    func testRigidLeverReturnsUprightOnRelease() {
        var c = FlightController(); let p = grab(&c)
        _ = settle(&c,at: p+SIMD3(0.06,0,-0.04))
        let direction = FlightController.leverDirection(c.stick.deflection)
        XCTAssertEqual(simd_length(direction),1,accuracy: 0.0001); XCTAssertGreaterThan(direction.x,0); XCTAssertLessThan(direction.z,0)
        c.reset(); XCTAssertEqual(FlightController.leverDirection(c.stick.deflection),SIMD3(0,1,0))
    }
    func testMovementFrameRateAndPhysicalTrackingPreserved() {
        for hz in [72,90,96] {
            var pose = NavigationPose(); pose.begin(at: head)
            var m = FlightMotion(); m.forward = 1; m.trackingForward = simd_normalize(SIMD3(1,1,-1))
            for _ in 0..<hz { pose.fly(m,deltaTime: 1/Float(hz),head: head) }
            XCTAssertEqual(pose.worldFromTracking.columns.3.x,1/sqrt(3),accuracy: 0.001)
            XCTAssertEqual(pose.worldFromTracking.columns.3.y,1/sqrt(3),accuracy: 0.001)
            let before = pose.worldFromTracking, walked = translation(SIMD3(1,1.65,0))
            pose.fly(FlightMotion(),deltaTime: dt,head: walked)
            XCTAssertEqual(pose.worldFromTracking,before)
            XCTAssertEqual((pose.worldFromTracking*walked).columns.3.x,1+1/sqrt(3),accuracy: 0.001)
        }
    }
    func testPanelButtonsRequireFreshPinchAndEmitOnce() {
        for action in [FlightPanelAction.menu,.exit] {
            var c = FlightController(); c.bringPanelHere(head: head)
            let p = point(c,local: FlightController.buttonCenter(action))
            _ = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
            XCTAssertNil(c.panelAction)
            _ = c.update(head: head,hands: [hand(p,pinch: 0.07)],deltaTime: dt,enabled: true)
            let motion = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
            XCTAssertEqual(c.panelAction,action); XCTAssertFalse(c.isHeld); XCTAssertFalse(c.isMovingPanel)
            XCTAssertEqual(motion.forward,0); XCTAssertEqual(motion.yaw,0)
            _ = c.update(head: head,hands: [hand(p)],deltaTime: dt,enabled: true)
            XCTAssertNil(c.panelAction)
        }
    }
    func testExitWithFreeHandStopsFlightBeforeSceneAction() {
        var c = FlightController(); let p = grab(&c,side: .left)
        _ = settle(&c,at: p+SIMD3(0,0,-0.06),side: .left)
        let button = point(c,local: FlightController.buttonCenter(.exit))
        _ = c.update(head: head,hands: [hand(p,side: .left),hand(button,pinch: 0.07)],deltaTime: dt,enabled: true)
        let motion = c.update(head: head,hands: [hand(p,side: .left),hand(button)],deltaTime: dt,enabled: true)
        XCTAssertEqual(c.panelAction,.exit); XCTAssertEqual(motion.forward,0); XCTAssertFalse(c.isHeld)
    }

    func testRadialPlacementKeepsOffCenterPinchAttached() {
        var c = FlightController(); c.bringPanelHere(head: head)
        let local = FlightController.moveHandleCenter + SIMD3<Float>(0.04,0,0)
        let initial = point(c,local: local)
        _ = c.update(head: head,hands: [hand(initial,pinch: 0.07)],deltaTime: dt,enabled: true)
        _ = c.update(head: head,hands: [hand(initial)],deltaTime: dt,enabled: true)
        XCTAssertTrue(c.isMovingPanel)
        for x: Float in [0.03,0.06,0.09,0.12] {
            let target = initial+SIMD3(x,0.05,0)
            _ = c.update(head: head,hands: [hand(target)],deltaTime: dt,enabled: true)
            XCTAssertLessThan(simd_distance(point(c,local: local),target),0.001)
            let d = simd_normalize(SIMD2(head.columns.3.x-c.panelTransform.columns.3.x,head.columns.3.z-c.panelTransform.columns.3.z))
            XCTAssertGreaterThan(simd_dot(d,SIMD2(c.panelTransform.columns.2.x,c.panelTransform.columns.2.z)),0.999)
        }
    }
    func testNudgingReorientsPanelTowardHeadset() {
        var c = FlightController(); c.bringPanelHere(head: head)
        let movedHead = translation(SIMD3(0.25,1.65,0))
        c.adjustPanel(height: 0.05,distance: 0,head: movedHead)
        let d = simd_normalize(SIMD2(0.25-c.panelTransform.columns.3.x,-c.panelTransform.columns.3.z))
        XCTAssertGreaterThan(simd_dot(d,SIMD2(c.panelTransform.columns.2.x,c.panelTransform.columns.2.z)),0.999)
    }
    func testLowRailStillSeparateFromRaisedButtonsAndStick() {
        XCTAssertEqual(FlightController.moveHandleCenter.y,0.028,accuracy: 0.0001)
        XCTAssertEqual(FlightController.buttonCenter(.menu).y,0.014,accuracy: 0.0001)
        var c = FlightController(); grab(&c,placement: true)
        XCTAssertTrue(c.isMovingPanel); XCTAssertNil(c.panelAction); XCTAssertFalse(c.isHeld)
    }

    func testScanButtonsRespectEndpointsAndRequireNewPinches() {
        for action in [FlightPanelAction.previous,.next] {
            for allowed in [false,true] {
                var c = FlightController(); c.bringPanelHere(head: head)
                let p = point(c,local: FlightController.buttonCenter(action))
                func update(_ pinch: Float) -> FlightMotion {
                    c.update(head: head,hands: [hand(p,pinch: pinch)],deltaTime: dt,enabled: true,
                             canGoPrevious: action == .previous && allowed,canGoNext: action == .next && allowed)
                }
                _ = update(0.015); XCTAssertNil(c.panelAction)
                _ = update(0.07)
                let motion = update(0.015)
                XCTAssertEqual(c.panelAction,allowed ? action : nil)
                XCTAssertEqual(motion.forward,0); XCTAssertEqual(motion.yaw,0)
                XCTAssertFalse(c.isHeld); XCTAssertFalse(c.isMovingPanel)
                _ = update(0.015); XCTAssertNil(c.panelAction)
            }
        }
    }
    func testLoadingDisablesScanButtonsButKeepsMenuAndExit() {
        for action in [FlightPanelAction.menu,.exit,.previous,.next] {
            var c = FlightController(); c.bringPanelHere(head: head)
            let p = point(c,local: FlightController.buttonCenter(action))
            for pinch: Float in [0.07,0.015] {
                _ = c.update(head: head,hands: [hand(p,pinch: pinch)],deltaTime: dt,enabled: true,
                             flightAllowed: false,canGoPrevious: true,canGoNext: true)
            }
            XCTAssertEqual(c.panelAction,(action == .menu || action == .exit) ? action : nil)
            XCTAssertFalse(c.canFly); XCTAssertFalse(c.previousEnabled); XCTAssertFalse(c.nextEnabled)
        }
    }
    func testLoadingStopsFlightButAllowsPanelPlacement() {
        var c = FlightController(); let p = grab(&c)
        _ = settle(&c,at: p+SIMD3(0,0,-0.065))
        let motion = c.update(head: head,hands: [hand(p+SIMD3(0,0,-0.065))],deltaTime: dt,enabled: true,flightAllowed: false)
        XCTAssertEqual(motion.forward,0); XCTAssertEqual(motion.yaw,0); XCTAssertFalse(c.isHeld)
        let rail = point(c,local: FlightController.moveHandleCenter)
        for pinch: Float in [0.07,0.015] {
            _ = c.update(head: head,hands: [hand(rail,pinch: pinch)],deltaTime: dt,enabled: true,flightAllowed: false)
        }
        XCTAssertTrue(c.isMovingPanel); XCTAssertFalse(c.isHeld)
    }

}
