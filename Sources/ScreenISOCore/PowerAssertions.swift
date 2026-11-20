import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionKind: String, Codable, CaseIterable, Comparable, Sendable {
    case preventDisplaySleep
    case preventIdleSystemSleep
    case preventSystemSleep
    case preventDiskIdle
    case userIsActive

    /// IOKit assertion type name passed to `IOPMAssertionCreateWithName`.
    public var assertionType: String {
        switch self {
        case .preventDisplaySleep: "PreventUserIdleDisplaySleep"
        case .preventIdleSystemSleep: "PreventUserIdleSystemSleep"
        case .preventSystemSleep: "PreventSystemSleep"
        case .preventDiskIdle: "PreventDiskIdle"
        case .userIsActive: "UserIsActive"
        }
    }

    /// The `caffeinate` flag that creates the same assertion. `caffeinate -u` alone expires after 5 seconds;
    /// here the assertion is held until it is released.
    public var caffeinateFlag: String {
        switch self {
        case .preventDisplaySleep: "-d"
        case .preventIdleSystemSleep: "-i"
        case .preventSystemSleep: "-s"
        case .preventDiskIdle: "-m"
        case .userIsActive: "-u"
        }
    }

    public static func < (lhs: PowerAssertionKind, rhs: PowerAssertionKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

@MainActor
public protocol PowerAssertionManaging: AnyObject {
    var heldKinds: Set<PowerAssertionKind> { get }
    /// Does nothing when the kind is already held.
    func acquire(_ kind: PowerAssertionKind, reason: String) throws
    /// Does nothing when the kind is not held. A kind whose release fails is no longer tracked as held.
    func release(_ kind: PowerAssertionKind) throws
}

@MainActor
public final class IOKitPowerAssertionManager: PowerAssertionManaging {
    private var assertions: [PowerAssertionKind: IOPMAssertionID] = [:]

    public init() {}

    public var heldKinds: Set<PowerAssertionKind> { Set(assertions.keys) }

    public func acquire(_ kind: PowerAssertionKind, reason: String) throws {
        guard assertions[kind] == nil else { return }
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            Log.power.error("power_assertion_create_failed kind=\(kind.rawValue, privacy: .public) ioReturn=\(result)")
            throw ScreenISOError.powerAssertionCreateFailed(kind: kind, ioReturn: result)
        }
        assertions[kind] = assertionID
        Log.power.info("power_assertion_acquired kind=\(kind.rawValue, privacy: .public) id=\(assertionID)")
    }

    public func release(_ kind: PowerAssertionKind) throws {
        guard let assertionID = assertions.removeValue(forKey: kind) else { return }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            Log.power.error("power_assertion_release_failed kind=\(kind.rawValue, privacy: .public) ioReturn=\(result)")
            throw ScreenISOError.powerAssertionReleaseFailed(kind: kind, ioReturn: result)
        }
        Log.power.info("power_assertion_released kind=\(kind.rawValue, privacy: .public)")
    }
}
