import Foundation

public enum LockMode: String, Codable, CaseIterable, Sendable {
    /// `SACLockScreenImmediate`: the loginwindow lock screen.
    case loginWindow
    /// ScreenSaverEngine, which locks through the immediate screen lock policy.
    case screenSaver
}

public struct SessionConfiguration: Codable, Equatable, Sendable {
    public var powerAssertions: Set<PowerAssertionKind>
    public var keepAwakeWithLidClosed: Bool
    public var lockMode: LockMode

    public init(
        powerAssertions: Set<PowerAssertionKind> = [.preventIdleSystemSleep, .preventSystemSleep],
        keepAwakeWithLidClosed: Bool = false,
        lockMode: LockMode = .loginWindow
    ) {
        self.powerAssertions = powerAssertions
        self.keepAwakeWithLidClosed = keepAwakeWithLidClosed
        self.lockMode = lockMode
    }

    public static let `default` = SessionConfiguration()

    private enum CodingKeys: String, CodingKey {
        case powerAssertions
        case keepAwakeWithLidClosed
        case lockMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        powerAssertions = Set(try container.decode([PowerAssertionKind].self, forKey: .powerAssertions))
        keepAwakeWithLidClosed = try container.decode(Bool.self, forKey: .keepAwakeWithLidClosed)
        lockMode = try container.decode(LockMode.self, forKey: .lockMode)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(powerAssertions.sorted(), forKey: .powerAssertions)
        try container.encode(keepAwakeWithLidClosed, forKey: .keepAwakeWithLidClosed)
        try container.encode(lockMode, forKey: .lockMode)
    }
}
