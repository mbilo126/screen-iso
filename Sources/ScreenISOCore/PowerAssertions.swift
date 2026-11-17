import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionKind: String, Codable, CaseIterable, Comparable, Sendable {
    case preventIdleSystemSleep
    case preventSystemSleep
    case preventDisplaySleep
    case preventDiskIdle

    /// IOKit assertion type name passed to `IOPMAssertionCreateWithName`.
    public var assertionType: String {
        switch self {
        case .preventIdleSystemSleep: "PreventUserIdleSystemSleep"
        case .preventSystemSleep: "PreventSystemSleep"
        case .preventDisplaySleep: "PreventUserIdleDisplaySleep"
        case .preventDiskIdle: "PreventDiskIdle"
        }
    }

    /// The `caffeinate` flag that creates the same assertion.
    public var caffeinateFlag: String {
        switch self {
        case .preventIdleSystemSleep: "-i"
        case .preventSystemSleep: "-s"
        case .preventDisplaySleep: "-d"
        case .preventDiskIdle: "-m"
        }
    }

    public static func < (lhs: PowerAssertionKind, rhs: PowerAssertionKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

@MainActor
public protocol PowerAssertionManaging: AnyObject {
    var heldKinds: Set<PowerAssertionKind> { get }
    /// Acquires every kind not already held. On failure, assertions created by this call are released.
    func acquire(_ kinds: Set<PowerAssertionKind>, reason: String) throws
    /// Releases every held assertion, attempting all of them even when one fails.
    func releaseAll() throws
}

@MainActor
public final class IOKitPowerAssertionManager: PowerAssertionManaging {
    private var assertions: [PowerAssertionKind: IOPMAssertionID] = [:]

    public init() {}

    public var heldKinds: Set<PowerAssertionKind> { Set(assertions.keys) }

    public func acquire(_ kinds: Set<PowerAssertionKind>, reason: String) throws {
        var created: [PowerAssertionKind] = []
        for kind in kinds.sorted() where assertions[kind] == nil {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kind.assertionType as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                Log.power.error(
                    "power_assertion_create_failed kind=\(kind.rawValue, privacy: .public) ioReturn=\(result)"
                )
                for createdKind in created {
                    if let id = assertions.removeValue(forKey: createdKind) {
                        IOPMAssertionRelease(id)
                    }
                }
                throw ScreenISOError.powerAssertionCreateFailed(kind: kind, ioReturn: result)
            }
            assertions[kind] = assertionID
            created.append(kind)
            Log.power.info("power_assertion_acquired kind=\(kind.rawValue, privacy: .public) id=\(assertionID)")
        }
    }

    public func releaseAll() throws {
        var failures: [ScreenISOError] = []
        for (kind, assertionID) in assertions.sorted(by: { $0.key < $1.key }) {
            let result = IOPMAssertionRelease(assertionID)
            assertions[kind] = nil
            if result == kIOReturnSuccess {
                Log.power.info("power_assertion_released kind=\(kind.rawValue, privacy: .public)")
            } else {
                Log.power.error(
                    "power_assertion_release_failed kind=\(kind.rawValue, privacy: .public) ioReturn=\(result)"
                )
                failures.append(.powerAssertionReleaseFailed(kind: kind, ioReturn: result))
            }
        }
        if let failure = ScreenISOError.combining(failures) {
            throw failure
        }
    }
}
