import Foundation

public struct BubbleConfiguration: Sendable, Equatable {
    public static let radiusLimits: ClosedRange<Float> = 60...360
    public static let defaultRadius: Float = 60
    public let radius: Float
    public init(radius: Float) {
        self.radius = radius.isFinite ? min(max(radius, Self.radiusLimits.lowerBound), Self.radiusLimits.upperBound) : Self.defaultRadius
    }
    public var overlap: Float { min(5, radius / 5) }
    public var fadeStart: Float { radius - overlap }
    public var refreshDistance: Float { overlap }
}
