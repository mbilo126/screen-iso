import Foundation
import Observation

public struct ActiveLock: Equatable, Sendable {
    public var lockId: UUID
    public var lockedAt: Date
    public var mode: LockMode
    public var method: LockMethod
}

public enum LockPhase: Equatable, Sendable {
    case unlocked
    case locking(lockId: UUID)
    case locked(ActiveLock)
}

public struct LockConfirmationPolicy: Equatable, Sendable {
    public var interval: Duration
    public var timeout: Duration

    public init(interval: Duration = .milliseconds(250), timeout: Duration = .seconds(5)) {
        self.interval = interval
        self.timeout = timeout
    }

    /// Number of waits between checks; the screen is checked once more than this.
    public var waits: Int { max(1, Int((timeout / interval).rounded(.up))) }
}

/// Holds the keep-awake activities the user switched on and locks the screen on request. The two are independent:
/// locking and unlocking never change an activity, which stays until it is switched off or the app quits.
@MainActor
@Observable
public final class ActivityController {
    public private(set) var activeAssertions: Set<PowerAssertionKind> = []
    public private(set) var lockPhase: LockPhase = .unlocked
    public private(set) var lastError: ScreenISOError?

    @ObservationIgnored private let powerAssertions: any PowerAssertionManaging
    @ObservationIgnored private let lidSleep: any LidSleepControlling
    @ObservationIgnored private let lockPolicy: any ScreenLockPolicyProviding
    @ObservationIgnored private let screenLock: any ScreenLockControlling
    @ObservationIgnored private let lockEvents: any ScreenLockEventObserving
    @ObservationIgnored private let auditLog: any AuditLogging
    @ObservationIgnored private let confirmation: LockConfirmationPolicy
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    @ObservationIgnored private var lockSignalReceived = false
    @ObservationIgnored private var unlockReceivedWhileLocking = false

    public static let assertionReason = "ScreenISO keep awake"

    public init(
        powerAssertions: any PowerAssertionManaging,
        lidSleep: any LidSleepControlling,
        lockPolicy: any ScreenLockPolicyProviding,
        screenLock: any ScreenLockControlling,
        lockEvents: any ScreenLockEventObserving,
        auditLog: any AuditLogging,
        confirmation: LockConfirmationPolicy = LockConfirmationPolicy(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.powerAssertions = powerAssertions
        self.lidSleep = lidSleep
        self.lockPolicy = lockPolicy
        self.screenLock = screenLock
        self.lockEvents = lockEvents
        self.auditLog = auditLog
        self.confirmation = confirmation
        self.now = now
        self.sleep = sleep
        activeAssertions = powerAssertions.heldKinds
    }

    public static func live(auditLogURL: URL = FileAuditLog.defaultURL) -> ActivityController {
        let runner = ProcessCommandRunner()
        return ActivityController(
            powerAssertions: IOKitPowerAssertionManager(),
            lidSleep: PmsetLidSleepController(runner: runner),
            lockPolicy: SysadminctlScreenLockPolicyProvider(runner: runner),
            screenLock: SystemScreenLockController(),
            lockEvents: DistributedScreenLockObserver(),
            auditLog: FileAuditLog(url: auditLogURL)
        )
    }

    // MARK: - Activities

    /// Acquires or releases one power assertion and audits the change. Nothing releases it afterwards.
    public func setAssertion(_ kind: PowerAssertionKind, active: Bool) throws {
        lastError = nil
        guard powerAssertions.heldKinds.contains(kind) != active else { return }
        defer { activeAssertions = powerAssertions.heldKinds }
        do {
            if active {
                try powerAssertions.acquire(kind, reason: Self.assertionReason)
            } else {
                try powerAssertions.release(kind)
            }
            try auditLog.append(
                entry(
                    .powerAssertionChanged,
                    id: UUID(),
                    details: [
                        "kind": .string(kind.rawValue),
                        "caffeinateFlag": .string(kind.caffeinateFlag),
                        "value": .bool(active),
                        "powerAssertions": .string(Self.list(powerAssertions.heldKinds)),
                    ]
                )
            )
        } catch {
            throw fail(ScreenISOError(error))
        }
    }

    /// Switches every assertion on or off, auditing each real change. All of them are attempted even when one fails.
    public func setAllAssertions(active: Bool) throws {
        lastError = nil
        var errors: [ScreenISOError] = []
        for kind in PowerAssertionKind.allCases {
            do {
                try setAssertion(kind, active: active)
            } catch {
                errors.append(ScreenISOError(error))
            }
        }
        if let failure = ScreenISOError.combining(errors) {
            throw fail(failure)
        }
    }

    /// Changes `pmset disablesleep` on explicit user request. Nothing restores it: the value stays until it is
    /// changed again, also after the app quits.
    public func setSleepDisabled(_ disabled: Bool) async throws {
        lastError = nil
        do {
            guard try await lidSleep.isSudoRuleActive() else {
                throw ScreenISOError.sudoRuleMissing
            }
            let previous = try await lidSleep.isSleepDisabled()
            try await lidSleep.setSleepDisabled(disabled)
            try auditLog.append(
                entry(
                    .sleepDisabledChanged,
                    id: UUID(),
                    details: ["value": .bool(disabled), "previousValue": .bool(previous)]
                )
            )
        } catch {
            throw fail(ScreenISOError(error))
        }
        Log.activity.notice("sleep_disabled_changed value=\(disabled)")
    }

    // MARK: - Lock

    /// Locks the screen and waits for macOS to confirm it. The activities are left exactly as they are.
    public func lock(_ mode: LockMode) async throws {
        guard lockPhase == .unlocked else {
            throw fail(.lockAlreadyInProgress)
        }
        let lockId = UUID()
        lockPhase = .locking(lockId: lockId)
        lastError = nil
        Log.activity.info(
            "lock_requested id=\(lockId.uuidString, privacy: .public) mode=\(mode.rawValue, privacy: .public)")

        let policy: ScreenLockPolicyStatus
        let sleepDisabled: Bool
        do {
            policy = try await lockPolicy.currentPolicy()
            guard policy.policy.isCompliant else {
                throw ScreenISOError.screenLockNotImmediate(policy.policy)
            }
            sleepDisabled = try await lidSleep.isSleepDisabled()
        } catch {
            let failure = ScreenISOError(error)
            recordSecondary(
                .preconditionFailed,
                id: lockId,
                details: [
                    "lockMode": .string(mode.rawValue),
                    "errorCode": .string(failure.code),
                    "message": .string(failure.message),
                ]
            )
            lockPhase = .unlocked
            throw fail(failure)
        }

        lockSignalReceived = false
        unlockReceivedWhileLocking = false
        lockEvents.startObserving { [weak self] event in
            await self?.handle(event)
        }

        let method: LockMethod
        do {
            method = try await performLock(mode)
        } catch {
            let failure = ScreenISOError(error)
            lockEvents.stopObserving()
            recordSecondary(
                .lockFailed,
                id: lockId,
                details: [
                    "lockMode": .string(mode.rawValue),
                    "errorCode": .string(failure.code),
                    "message": .string(failure.message),
                ]
            )
            lockPhase = .unlocked
            throw fail(failure)
        }

        let lock = ActiveLock(lockId: lockId, lockedAt: now(), mode: mode, method: method)
        lockPhase = .locked(lock)
        Log.activity.info(
            "screen_locked id=\(lockId.uuidString, privacy: .public) method=\(method.rawValue, privacy: .public)")
        do {
            try auditLog.append(
                entry(
                    .screenLocked,
                    id: lockId,
                    at: lock.lockedAt,
                    details: [
                        "lockMode": .string(mode.rawValue),
                        "lockMethod": .string(method.rawValue),
                        "powerAssertions": .string(Self.list(powerAssertions.heldKinds)),
                        "sleepDisabled": .bool(sleepDisabled),
                        "screenLockPolicy": .string(policy.raw),
                    ]
                )
            )
        } catch {
            // The screen is already locked: undoing it is impossible, so the failure is surfaced, not thrown.
            let failure = ScreenISOError(error)
            Log.audit.fault("audit_write_failed event=screen_locked error=\(failure.message, privacy: .public)")
            lastError = failure
        }

        if unlockReceivedWhileLocking {
            finishFromUnlock(lock)
        }
    }

    private func performLock(_ mode: LockMode) async throws -> LockMethod {
        switch mode {
        case .loginWindow:
            try screenLock.lockNow()
            guard try await waitForLock() else {
                throw ScreenISOError.lockNotConfirmed(lockMode: mode)
            }
            return .loginWindow
        case .screenSaver:
            do {
                try await screenLock.startScreenSaver()
                if try await waitForLock() {
                    return .screenSaver
                }
                Log.lock.notice("screen_saver_lock_not_confirmed fallback=login_window")
            } catch let error as ScreenISOError {
                guard case .screenSaverLaunchFailed = error else { throw error }
                Log.lock.notice("screen_saver_launch_failed fallback=login_window")
            }
            try screenLock.lockNow()
            guard try await waitForLock() else {
                throw ScreenISOError.lockNotConfirmed(lockMode: mode)
            }
            return .loginWindowFallback
        }
    }

    private func waitForLock() async throws -> Bool {
        for wait in 0...confirmation.waits {
            if lockSignalReceived {
                return true
            }
            if try screenLock.isScreenLocked() {
                return true
            }
            if wait < confirmation.waits {
                try await sleep(confirmation.interval)
            }
        }
        return false
    }

    // MARK: - Lock events

    func handle(_ event: ScreenLockEvent) async {
        switch (event, lockPhase) {
        case (.locked, .locking):
            lockSignalReceived = true
        case (.unlocked, .locking):
            unlockReceivedWhileLocking = true
        case (.unlocked, .locked(let lock)):
            finishFromUnlock(lock)
        default:
            Log.activity.debug("screen_lock_event_ignored event=\(event.rawValue, privacy: .public)")
        }
    }

    private func finishFromUnlock(_ lock: ActiveLock) {
        lockEvents.stopObserving()
        let unlockedAt = now()
        lockPhase = .unlocked
        Log.activity.info("screen_unlocked id=\(lock.lockId.uuidString, privacy: .public)")
        do {
            try auditLog.append(
                entry(
                    .screenUnlocked,
                    id: lock.lockId,
                    at: unlockedAt,
                    details: [
                        "lockedDurationSeconds": .number(Self.seconds(from: lock.lockedAt, to: unlockedAt)),
                        "powerAssertions": .string(Self.list(powerAssertions.heldKinds)),
                    ]
                )
            )
        } catch {
            // Called from a notification: there is no caller to rethrow to, so the error is kept for the UI.
            let failure = ScreenISOError(error)
            Log.audit.fault("audit_write_failed event=screen_unlocked error=\(failure.message, privacy: .public)")
            lastError = failure
        }
    }

    // MARK: - Helpers

    private func entry(
        _ event: AuditEvent,
        id: UUID,
        at timestamp: Date? = nil,
        details: [String: AuditValue] = [:]
    ) -> AuditEntry {
        AuditEntry(timestamp: timestamp ?? now(), event: event, sessionId: id, details: details)
    }

    /// Writes an audit entry on a path that is already failing; the primary error wins over the audit error.
    private func recordSecondary(_ event: AuditEvent, id: UUID, details: [String: AuditValue]) {
        do {
            try auditLog.append(entry(event, id: id, details: details))
        } catch {
            Log.audit.fault(
                "audit_write_failed event=\(event.rawValue, privacy: .public) error=\(ScreenISOError(error).message, privacy: .public)"
            )
        }
    }

    private func fail(_ error: ScreenISOError) -> ScreenISOError {
        lastError = error
        Log.activity.error("activity_error code=\(error.code, privacy: .public)")
        return error
    }

    private static func list(_ kinds: Set<PowerAssertionKind>) -> String {
        kinds.sorted().map(\.rawValue).joined(separator: ",")
    }

    private static func seconds(from start: Date, to end: Date) -> Double {
        (end.timeIntervalSince(start) * 1000).rounded() / 1000
    }
}
