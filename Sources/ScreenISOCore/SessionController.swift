import Foundation
import Observation

public enum LockMethod: String, Codable, Sendable {
    case loginWindow
    case screenSaver
    /// The screen saver did not confirm the lock and `SACLockScreenImmediate` did.
    case loginWindowFallback
}

public enum SessionEndTrigger: String, Codable, Sendable {
    case screenUnlocked
    case manual
}

public struct ActiveSession: Equatable, Sendable {
    public var sessionId: UUID
    public var startedAt: Date
    public var lockedAt: Date
    public var lockMethod: LockMethod
    public var configuration: SessionConfiguration
    public var previousSleepDisabled: Bool
}

public enum SessionPhase: Equatable, Sendable {
    case idle
    case starting(sessionId: UUID, startedAt: Date)
    case active(ActiveSession)
    case ending(ActiveSession)
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

@MainActor
@Observable
public final class SessionController {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var lastError: ScreenISOError?

    @ObservationIgnored private let powerAssertions: any PowerAssertionManaging
    @ObservationIgnored private let lidSleep: any LidSleepControlling
    @ObservationIgnored private let lockPolicy: any ScreenLockPolicyProviding
    @ObservationIgnored private let screenLock: any ScreenLockControlling
    @ObservationIgnored private let lockEvents: any ScreenLockEventObserving
    @ObservationIgnored private let auditLog: any AuditLogging
    @ObservationIgnored private let snapshotStore: any SessionSnapshotStoring
    @ObservationIgnored private let confirmation: LockConfirmationPolicy
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    @ObservationIgnored private var lockSignalReceived = false
    @ObservationIgnored private var unlockReceivedWhileStarting = false

    public static let assertionReason = "ScreenISO protected session"

    public init(
        powerAssertions: any PowerAssertionManaging,
        lidSleep: any LidSleepControlling,
        lockPolicy: any ScreenLockPolicyProviding,
        screenLock: any ScreenLockControlling,
        lockEvents: any ScreenLockEventObserving,
        auditLog: any AuditLogging,
        snapshotStore: any SessionSnapshotStoring,
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
        self.snapshotStore = snapshotStore
        self.confirmation = confirmation
        self.now = now
        self.sleep = sleep
    }

    public static func live(
        auditLogURL: URL = FileAuditLog.defaultURL,
        snapshotURL: URL = FileSessionSnapshotStore.defaultURL
    ) -> SessionController {
        let runner = ProcessCommandRunner()
        return SessionController(
            powerAssertions: IOKitPowerAssertionManager(),
            lidSleep: PmsetLidSleepController(runner: runner),
            lockPolicy: SysadminctlScreenLockPolicyProvider(runner: runner),
            screenLock: SystemScreenLockController(),
            lockEvents: DistributedScreenLockObserver(),
            auditLog: FileAuditLog(url: auditLogURL),
            snapshotStore: FileSessionSnapshotStore(url: snapshotURL)
        )
    }

    // MARK: - Start

    public func start(_ configuration: SessionConfiguration = .default) async throws {
        guard phase == .idle else {
            throw fail(.sessionAlreadyRunning)
        }
        let sessionId = UUID()
        let startedAt = now()
        phase = .starting(sessionId: sessionId, startedAt: startedAt)
        lastError = nil
        Log.session.info("session_start_requested session=\(sessionId.uuidString, privacy: .public)")

        let policy: ScreenLockPolicyStatus
        let previousSleepDisabled: Bool
        do {
            policy = try await checkPreconditions(configuration)
            previousSleepDisabled = try await lidSleep.isSleepDisabled()
        } catch {
            let failure = ScreenISOError(error)
            recordSecondary(
                .preconditionFailed,
                sessionId: sessionId,
                details: ["errorCode": .string(failure.code), "message": .string(failure.message)]
            )
            phase = .idle
            throw fail(failure)
        }

        let snapshot = SessionSnapshot(
            sessionId: sessionId,
            startedAt: startedAt,
            configuration: configuration,
            previousSleepDisabled: previousSleepDisabled
        )
        var applied = AppliedEffects()
        var stage = "save_snapshot"
        do {
            try snapshotStore.save(snapshot)
            applied.snapshotSaved = true
            stage = "acquire_power_assertions"
            try powerAssertions.acquire(configuration.powerAssertions, reason: Self.assertionReason)
            if configuration.keepAwakeWithLidClosed {
                stage = "disable_sleep"
                try await lidSleep.setSleepDisabled(true)
                applied.sleepDisabledChanged = true
            }
            stage = "audit_session_started"
            try auditLog.append(
                entry(.sessionStarted, sessionId: sessionId, details: startDetails(snapshot, policy: policy))
            )
        } catch {
            let failure = ScreenISOError(error)
            let rollbackErrors = await rollback(applied, previousSleepDisabled: previousSleepDisabled)
            recordSecondary(
                .sessionStartFailed,
                sessionId: sessionId,
                details: [
                    "stage": .string(stage),
                    "errorCode": .string(failure.code),
                    "message": .string(failure.message),
                    "rolledBack": .bool(rollbackErrors.isEmpty),
                    "rollbackErrorCodes": .string(rollbackErrors.map(\.code).joined(separator: ",")),
                ]
            )
            phase = .idle
            throw fail(ScreenISOError.combining([failure] + rollbackErrors) ?? failure)
        }

        lockSignalReceived = false
        unlockReceivedWhileStarting = false
        lockEvents.startObserving { [weak self] event in
            await self?.handle(event)
        }

        let lockMethod: LockMethod
        do {
            lockMethod = try await lock(mode: configuration.lockMode)
        } catch {
            let failure = ScreenISOError(error)
            lockEvents.stopObserving()
            let rollbackErrors = await rollback(applied, previousSleepDisabled: previousSleepDisabled)
            recordSecondary(
                .lockFailed,
                sessionId: sessionId,
                details: [
                    "lockMode": .string(configuration.lockMode.rawValue),
                    "errorCode": .string(failure.code),
                    "message": .string(failure.message),
                    "rolledBack": .bool(rollbackErrors.isEmpty),
                    "rollbackErrorCodes": .string(rollbackErrors.map(\.code).joined(separator: ",")),
                ]
            )
            phase = .idle
            throw fail(ScreenISOError.combining([failure] + rollbackErrors) ?? failure)
        }

        let session = ActiveSession(
            sessionId: sessionId,
            startedAt: startedAt,
            lockedAt: now(),
            lockMethod: lockMethod,
            configuration: configuration,
            previousSleepDisabled: previousSleepDisabled
        )
        phase = .active(session)
        Log.session.info(
            "session_active session=\(sessionId.uuidString, privacy: .public) lockMethod=\(lockMethod.rawValue, privacy: .public)"
        )
        do {
            try auditLog.append(
                entry(
                    .screenLocked,
                    sessionId: sessionId,
                    details: [
                        "lockMode": .string(configuration.lockMode.rawValue),
                        "lockMethod": .string(lockMethod.rawValue),
                    ]
                )
            )
        } catch {
            // The screen is already locked: undoing it is impossible, so the failure is surfaced, not thrown.
            let failure = ScreenISOError(error)
            Log.audit.fault("audit_write_failed event=screen_locked error=\(failure.message, privacy: .public)")
            lastError = failure
        }

        if unlockReceivedWhileStarting {
            await finishFromUnlock(session)
        }
    }

    private func checkPreconditions(_ configuration: SessionConfiguration) async throws -> ScreenLockPolicyStatus {
        let policy = try await lockPolicy.currentPolicy()
        guard policy.policy.isCompliant else {
            throw ScreenISOError.screenLockNotImmediate(policy.policy)
        }
        if configuration.keepAwakeWithLidClosed {
            guard try await lidSleep.isSudoRuleActive() else {
                throw ScreenISOError.sudoRuleMissing
            }
        }
        return policy
    }

    private func startDetails(_ snapshot: SessionSnapshot, policy: ScreenLockPolicyStatus) -> [String: AuditValue] {
        let configuration = snapshot.configuration
        return [
            "powerAssertions": .string(configuration.powerAssertions.sorted().map(\.rawValue).joined(separator: ",")),
            "keepAwakeWithLidClosed": .bool(configuration.keepAwakeWithLidClosed),
            "lockMode": .string(configuration.lockMode.rawValue),
            "previousSleepDisabled": .bool(snapshot.previousSleepDisabled),
            "screenLockPolicy": .string(policy.raw),
        ]
    }

    // MARK: - Lock

    private func lock(mode: LockMode) async throws -> LockMethod {
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
        switch (event, phase) {
        case (.locked, .starting):
            lockSignalReceived = true
        case (.unlocked, .starting):
            unlockReceivedWhileStarting = true
        case (.unlocked, .active(let session)):
            await finishFromUnlock(session)
        default:
            Log.session.debug("screen_lock_event_ignored event=\(event.rawValue, privacy: .public)")
        }
    }

    private func finishFromUnlock(_ session: ActiveSession) async {
        do {
            try await finish(session, trigger: .screenUnlocked)
        } catch {
            // No caller to rethrow to: `finish` already stored the error in `lastError` for the UI.
            Log.session.error("session_end_after_unlock_failed error=\(ScreenISOError(error).code, privacy: .public)")
        }
    }

    // MARK: - End

    public func end() async throws {
        guard case .active(let session) = phase else {
            throw fail(.noActiveSession)
        }
        try await finish(session, trigger: .manual)
    }

    private func finish(_ session: ActiveSession, trigger: SessionEndTrigger) async throws {
        phase = .ending(session)
        lockEvents.stopObserving()
        let endedAt = now()
        var errors: [ScreenISOError] = []

        if trigger == .screenUnlocked {
            do {
                try auditLog.append(entry(.screenUnlocked, sessionId: session.sessionId, at: endedAt))
            } catch {
                errors.append(ScreenISOError(error))
            }
        }

        errors += await rollback(
            AppliedEffects(snapshotSaved: true, sleepDisabledChanged: session.configuration.keepAwakeWithLidClosed),
            previousSleepDisabled: session.previousSleepDisabled
        )

        let details: [String: AuditValue] = [
            "trigger": .string(trigger.rawValue),
            "durationSeconds": .number(Self.seconds(from: session.startedAt, to: endedAt)),
            "lockedDurationSeconds": .number(Self.seconds(from: session.lockedAt, to: endedAt)),
            "restoredSleepDisabled": .bool(session.previousSleepDisabled),
            "cleanupComplete": .bool(errors.isEmpty),
            "errorCodes": .string(errors.map(\.code).joined(separator: ",")),
        ]
        do {
            try auditLog.append(entry(.sessionEnded, sessionId: session.sessionId, at: endedAt, details: details))
        } catch {
            errors.append(ScreenISOError(error))
        }

        phase = .idle
        Log.session.info(
            "session_ended session=\(session.sessionId.uuidString, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) errors=\(errors.count)"
        )
        if let failure = ScreenISOError.combining(errors) {
            throw fail(failure)
        }
    }

    // MARK: - Recovery

    /// Undoes an orphaned session left by a crash. Returns the recovered snapshot, or nil when there was none.
    @discardableResult
    public func recoverIfNeeded() async throws -> SessionSnapshot? {
        guard phase == .idle else {
            throw fail(.sessionAlreadyRunning)
        }
        let snapshot: SessionSnapshot
        do {
            guard let loaded = try snapshotStore.load() else { return nil }
            snapshot = loaded
        } catch {
            throw fail(ScreenISOError(error))
        }

        do {
            if snapshot.configuration.keepAwakeWithLidClosed {
                try await lidSleep.setSleepDisabled(snapshot.previousSleepDisabled)
            }
            try auditLog.append(
                entry(
                    .sessionRecovered,
                    sessionId: snapshot.sessionId,
                    details: [
                        "snapshotStartedAt": .string(JSONCoding.formatTimestamp(snapshot.startedAt)),
                        "keepAwakeWithLidClosed": .bool(snapshot.configuration.keepAwakeWithLidClosed),
                        "restoredSleepDisabled": .bool(snapshot.previousSleepDisabled),
                    ]
                )
            )
            try snapshotStore.delete()
        } catch {
            throw fail(ScreenISOError(error))
        }
        Log.session.notice("session_recovered session=\(snapshot.sessionId.uuidString, privacy: .public)")
        return snapshot
    }

    /// Deletes a snapshot that `recoverIfNeeded()` could not decode, on explicit user request. Nothing is restored,
    /// so the deletion is audited under a new id: the orphaned session's id is unreadable.
    public func discardSnapshot() throws {
        guard phase == .idle else {
            throw fail(.sessionAlreadyRunning)
        }
        let discardId = UUID()
        do {
            try snapshotStore.delete()
            try auditLog.append(
                entry(
                    .snapshotDiscarded,
                    sessionId: discardId,
                    details: ["previousErrorCode": .string(lastError?.code ?? "")]
                )
            )
        } catch {
            throw fail(ScreenISOError(error))
        }
        lastError = nil
        Log.session.notice("snapshot_discarded id=\(discardId.uuidString, privacy: .public)")
    }

    // MARK: - Helpers

    private struct AppliedEffects {
        var snapshotSaved = false
        var sleepDisabledChanged = false
    }

    /// Releases assertions, restores `disablesleep` and deletes the snapshot. The snapshot is kept when
    /// `disablesleep` could not be restored, so `recoverIfNeeded()` can retry at the next launch.
    private func rollback(_ applied: AppliedEffects, previousSleepDisabled: Bool) async -> [ScreenISOError] {
        var errors: [ScreenISOError] = []
        do {
            try powerAssertions.releaseAll()
        } catch {
            errors.append(ScreenISOError(error))
        }
        var sleepRestored = true
        if applied.sleepDisabledChanged {
            do {
                try await lidSleep.setSleepDisabled(previousSleepDisabled)
            } catch {
                sleepRestored = false
                errors.append(ScreenISOError(error))
            }
        }
        if applied.snapshotSaved && sleepRestored {
            do {
                try snapshotStore.delete()
            } catch {
                errors.append(ScreenISOError(error))
            }
        }
        for error in errors {
            Log.session.error("rollback_step_failed error=\(error.code, privacy: .public)")
        }
        return errors
    }

    private func entry(
        _ event: AuditEvent,
        sessionId: UUID,
        at timestamp: Date? = nil,
        details: [String: AuditValue] = [:]
    ) -> AuditEntry {
        AuditEntry(timestamp: timestamp ?? now(), event: event, sessionId: sessionId, details: details)
    }

    /// Writes an audit entry on a path that is already failing; the primary error wins over the audit error.
    private func recordSecondary(_ event: AuditEvent, sessionId: UUID, details: [String: AuditValue]) {
        do {
            try auditLog.append(entry(event, sessionId: sessionId, details: details))
        } catch {
            Log.audit.fault(
                "audit_write_failed event=\(event.rawValue, privacy: .public) error=\(ScreenISOError(error).message, privacy: .public)"
            )
        }
    }

    private func fail(_ error: ScreenISOError) -> ScreenISOError {
        lastError = error
        Log.session.error("session_error code=\(error.code, privacy: .public)")
        return error
    }

    private static func seconds(from start: Date, to end: Date) -> Double {
        (end.timeIntervalSince(start) * 1000).rounded() / 1000
    }
}
