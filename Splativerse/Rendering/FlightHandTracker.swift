import ARKit
import QuartzCore
import SplativerseCore
import os
import simd

/// Hand updates are timestamped on arrival so a stalled provider cannot leave
/// flight engaged. Only the compositor thread owns the gesture state machine.
final class FlightHandTracker: Sendable {
    let provider = HandTrackingProvider()
    private struct Timed: Sendable { let hand: FlightHand; let time: TimeInterval }
    private let samples = OSAllocatedUnfairLock(initialState: [FlightHand.Side: Timed]())
    func run() async {
        for await update in provider.anchorUpdates {
            if Task.isCancelled { break }
            let anchor = update.anchor
            let side: FlightHand.Side = anchor.chirality == .left ? .left : .right
            guard update.event != .removed, anchor.isTracked, let skeleton = anchor.handSkeleton else {
                _ = samples.withLock { $0.removeValue(forKey: side) }; continue
            }
            let thumb = skeleton.joint(.thumbTip), index = skeleton.joint(.indexFingerTip), wrist = skeleton.joint(.wrist)
            guard thumb.isTracked, index.isTracked, wrist.isTracked else {
                _ = samples.withLock { $0.removeValue(forKey: side) }; continue
            }
            let t = (anchor.originFromAnchorTransform * thumb.anchorFromJointTransform).columns.3
            let i = (anchor.originFromAnchorTransform * index.anchorFromJointTransform).columns.3
            let a = SIMD3(t.x, t.y, t.z), b = SIMD3(i.x, i.y, i.z)
            let hand = FlightHand(side: side, position: (a + b) * 0.5,
                orientation: simd_quatf(anchor.originFromAnchorTransform * wrist.anchorFromJointTransform), pinchDistance: simd_distance(a, b))
            samples.withLock { $0[side] = Timed(hand: hand, time: CACurrentMediaTime()) }
        }
        samples.withLock { $0.removeAll() }
    }
    func latest() -> [FlightHand] {
        guard provider.state == .running else { return [] }
        let now = CACurrentMediaTime()
        return samples.withLock { state in
            FlightHand.Side.allCases.compactMap { side in
                guard let value = state[side], now - value.time < 0.15 else { return nil }
                return value.hand
            }
        }
    }
}
