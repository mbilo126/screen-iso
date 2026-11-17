import Foundation
import Testing

@testable import ScreenISOCore

@MainActor
@Suite("SessionController")
struct SessionControllerTests {
    @Test("happy path locks, keeps the Mac awake and ends on unlock")
    func happyPath() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }

        try await harness.controller.start()

        guard case .active(let session) = harness.controller.phase else {
            Issue.record("Expected an active session, got \(harness.controller.phase)")
            return
        }
        #expect(session.lockMethod == .loginWindow)
        #expect(session.startedAt == SessionHarness.startDate)
        #expect(harness.power.heldKinds == [.preventIdleSystemSleep, .preventSystemSleep])
        #expect(harness.screen.lockNowCalls == 1)
        #expect(harness.screen.screenSaverCalls == 0)
        #expect(harness.lid.setCalls.isEmpty)
        #expect(harness.snapshotExists)
        #expect(harness.events.isObserving)
        #expect(try harness.auditEvents() == [.sessionStarted, .screenLocked])
        #expect(harness.controller.lastError == nil)

        let snapshot = try #require(try harness.snapshotStore.load())
        #expect(snapshot.sessionId == session.sessionId)
        #expect(snapshot.configuration == .default)
        #expect(snapshot.previousSleepDisabled == false)

        harness.clock.advance(by: 3600)
        await harness.events.emit(.unlocked)

        #expect(harness.controller.phase == .idle)
        #expect(harness.power.heldKinds.isEmpty)
        #expect(harness.power.releaseCalls == 1)
        #expect(harness.lid.setCalls.isEmpty)
        #expect(!harness.snapshotExists)
        #expect(!harness.events.isObserving)
        #expect(harness.controller.lastError == nil)

        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.sessionStarted, .screenLocked, .screenUnlocked, .sessionEnded])
        #expect(Set(entries.map(\.sessionId)) == [session.sessionId])
        let ended = try #require(entries.last)
        #expect(ended.details["trigger"] == "screenUnlocked")
        #expect(ended.details["durationSeconds"] == 3600)
        #expect(ended.details["cleanupComplete"] == true)
    }

    @Test("a non immediate screen lock policy fails before any side effect")
    func preconditionPolicy() async throws {
        let harness = try SessionHarness(
            policy: FakeLockPolicy(.delay(seconds: 300), raw: "screenLock delay is 300 seconds"))
        defer { harness.cleanUp() }

        await #expect(throws: ScreenISOError.screenLockNotImmediate(.delay(seconds: 300))) {
            try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        }

        assertNoSideEffects(harness)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.lastError?.code == "screen_lock_not_immediate")
        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.preconditionFailed])
        #expect(entries.first?.details["errorCode"] == "screen_lock_not_immediate")
    }

    @Test("a missing sudoers rule fails before any side effect when the lid option is on")
    func preconditionSudoRule() async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sudoRuleActive: false))
        defer { harness.cleanUp() }

        await #expect(throws: ScreenISOError.sudoRuleMissing) {
            try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        }

        assertNoSideEffects(harness)
        #expect(try harness.auditEvents() == [.preconditionFailed])
    }

    @Test("the sudoers rule is not required when the lid option is off")
    func sudoRuleNotRequired() async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sudoRuleActive: false))
        defer { harness.cleanUp() }

        try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: false))

        #expect(harness.controller.phase.isActive)
        #expect(harness.lid.setCalls.isEmpty)
    }

    @Test("an unconfirmed lock rolls everything back")
    func lockNotConfirmed() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false

        await #expect(throws: ScreenISOError.lockNotConfirmed(lockMode: .loginWindow)) {
            try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        }

        #expect(harness.controller.phase == .idle)
        #expect(harness.power.heldKinds.isEmpty)
        #expect(harness.power.releaseCalls == 1)
        #expect(harness.lid.setCalls == [true, false])
        #expect(harness.lid.sleepDisabled == false)
        #expect(!harness.snapshotExists)
        #expect(!harness.events.isObserving)
        // 5 s at 250 ms: one check per wait plus the initial one.
        #expect(harness.screen.lockChecks == 21)
        #expect(harness.clock.now() == SessionHarness.startDate.addingTimeInterval(5))

        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.sessionStarted, .lockFailed])
        #expect(entries.last?.details["rolledBack"] == true)
        #expect(entries.last?.details["errorCode"] == "lock_not_confirmed")
    }

    @Test("a missing lock symbol rolls everything back")
    func lockSymbolMissing() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        let symbolError = ScreenISOError.lockSymbolUnavailable(detail: "symbol not found")
        harness.screen.symbolError = symbolError

        await #expect(throws: symbolError) {
            try await harness.controller.start()
        }

        #expect(harness.power.heldKinds.isEmpty)
        #expect(!harness.snapshotExists)
        #expect(try harness.auditEvents() == [.sessionStarted, .lockFailed])
    }

    @Test("rollback keeps the snapshot when disablesleep cannot be restored")
    func rollbackKeepsSnapshotWhenRestoreFails() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false
        harness.lid.failingSetValues = [false]

        do {
            try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
            Issue.record("start should have thrown")
        } catch let error as ScreenISOError {
            guard case .cleanupIncomplete(let errors) = error else {
                Issue.record("Expected cleanup_incomplete, got \(error.code)")
                return
            }
            #expect(errors.map(\.code) == ["lock_not_confirmed", "command_failed"])
        }

        #expect(harness.snapshotExists)
        #expect(harness.power.heldKinds.isEmpty)
        let lockFailed = try #require(try harness.auditEntries().last)
        #expect(lockFailed.event == .lockFailed)
        #expect(lockFailed.details["rolledBack"] == false)
    }

    @Test("screen saver mode falls back to lockNow when the saver does not lock")
    func screenSaverFallback() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverLocks = false

        try await harness.controller.start(SessionConfiguration(lockMode: .screenSaver))

        guard case .active(let session) = harness.controller.phase else {
            Issue.record("Expected an active session")
            return
        }
        #expect(session.lockMethod == .loginWindowFallback)
        #expect(harness.screen.screenSaverCalls == 1)
        #expect(harness.screen.lockNowCalls == 1)
        let locked = try #require(try harness.auditEntries().last)
        #expect(locked.event == .screenLocked)
        #expect(locked.details["lockMethod"] == "loginWindowFallback")
    }

    @Test("screen saver mode falls back to lockNow when the saver cannot start")
    func screenSaverLaunchFallback() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverError = .screenSaverLaunchFailed(message: "not found")

        try await harness.controller.start(SessionConfiguration(lockMode: .screenSaver))

        #expect(harness.screen.lockNowCalls == 1)
        #expect(harness.controller.phase.activeSession?.lockMethod == .loginWindowFallback)
    }

    @Test("screen saver mode does not call lockNow when the saver locks")
    func screenSaverLocks() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }

        try await harness.controller.start(SessionConfiguration(lockMode: .screenSaver))

        #expect(harness.screen.lockNowCalls == 0)
        #expect(harness.controller.phase.activeSession?.lockMethod == .screenSaver)
    }

    @Test("screen saver mode rolls back when neither the saver nor lockNow lock")
    func screenSaverAndFallbackFail() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverLocks = false
        harness.screen.lockNowLocks = false

        await #expect(throws: ScreenISOError.lockNotConfirmed(lockMode: .screenSaver)) {
            try await harness.controller.start(SessionConfiguration(lockMode: .screenSaver))
        }
        #expect(harness.screen.lockChecks == 42)
        #expect(harness.power.heldKinds.isEmpty)
        #expect(!harness.snapshotExists)
    }

    @Test("unlock restores disablesleep to its value before the session", arguments: [false, true])
    func unlockRestoresSleepDisabled(previous: Bool) async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sleepDisabled: previous))
        defer { harness.cleanUp() }

        try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        #expect(harness.lid.sleepDisabled == true)
        #expect(try harness.snapshotStore.load()?.previousSleepDisabled == previous)

        await harness.events.emit(.unlocked)

        #expect(harness.lid.setCalls == [true, previous])
        #expect(harness.lid.sleepDisabled == previous)
        #expect(!harness.snapshotExists)
        let ended = try #require(try harness.auditEntries().last)
        #expect(ended.event == .sessionEnded)
        #expect(ended.details["restoredSleepDisabled"] == .bool(previous))
    }

    @Test("a lock notification confirms the lock even if the session flag lags")
    func lockNotificationConfirms() async throws {
        let events = FakeLockEvents()
        let harness = try SessionHarness(events: events, sleep: { _ in await events.emit(.locked) })
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false

        try await harness.controller.start()

        #expect(harness.controller.phase.isActive)
    }

    @Test("an unlock received while starting ends the session as soon as it is active")
    func unlockWhileStarting() async throws {
        let events = FakeLockEvents()
        let harness = try SessionHarness(
            events: events,
            sleep: { _ in
                await events.emit(.locked)
                await events.emit(.unlocked)
            }
        )
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false

        try await harness.controller.start()

        #expect(harness.controller.phase == .idle)
        #expect(
            try harness.auditEvents() == [.sessionStarted, .screenLocked, .screenUnlocked, .sessionEnded]
        )
    }

    @Test("manual end closes the session")
    func manualEnd() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }

        try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        try await harness.controller.end()

        #expect(harness.controller.phase == .idle)
        #expect(harness.lid.setCalls == [true, false])
        #expect(harness.power.heldKinds.isEmpty)
        let ended = try #require(try harness.auditEntries().last)
        #expect(ended.event == .sessionEnded)
        #expect(ended.details["trigger"] == "manual")
        #expect(try harness.auditEvents().contains(.screenUnlocked) == false)
    }

    @Test("end without a session and a second start are rejected")
    func invalidTransitions() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }

        await #expect(throws: ScreenISOError.noActiveSession) {
            try await harness.controller.end()
        }
        try await harness.controller.start()
        await #expect(throws: ScreenISOError.sessionAlreadyRunning) {
            try await harness.controller.start()
        }
        #expect(harness.controller.phase.isActive)
        #expect(harness.power.acquireCalls.count == 1)
    }

    @Test("a failure acquiring assertions rolls back and is audited")
    func assertionFailure() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        let failure = ScreenISOError.powerAssertionCreateFailed(kind: .preventSystemSleep, ioReturn: -536_870_212)
        harness.power.acquireError = failure

        await #expect(throws: failure) {
            try await harness.controller.start(SessionConfiguration(keepAwakeWithLidClosed: true))
        }

        #expect(harness.lid.setCalls.isEmpty)
        #expect(harness.screen.lockNowCalls == 0)
        #expect(!harness.snapshotExists)
        let entry = try #require(try harness.auditEntries().last)
        #expect(entry.event == .sessionStartFailed)
        #expect(entry.details["stage"] == "acquire_power_assertions")
    }

    @Test("recovery restores disablesleep from an orphaned snapshot")
    func recovery() async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sleepDisabled: true))
        defer { harness.cleanUp() }
        let orphan = SessionSnapshot(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_799_990_000),
            configuration: SessionConfiguration(keepAwakeWithLidClosed: true),
            previousSleepDisabled: false
        )
        try harness.snapshotStore.save(orphan)

        let recovered = try await harness.controller.recoverIfNeeded()

        #expect(recovered == orphan)
        #expect(harness.lid.setCalls == [false])
        #expect(harness.lid.sleepDisabled == false)
        #expect(!harness.snapshotExists)
        let entry = try #require(try harness.auditEntries().last)
        #expect(entry.event == .sessionRecovered)
        #expect(entry.sessionId == orphan.sessionId)
        #expect(entry.details["restoredSleepDisabled"] == false)
    }

    @Test("recovery leaves disablesleep alone when the orphaned session never changed it")
    func recoveryWithoutLidOption() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        try harness.snapshotStore.save(
            SessionSnapshot(
                sessionId: UUID(),
                startedAt: SessionHarness.startDate,
                configuration: .default,
                previousSleepDisabled: false
            )
        )

        let recovered = try await harness.controller.recoverIfNeeded()

        #expect(recovered != nil)
        #expect(harness.lid.setCalls.isEmpty)
        #expect(!harness.snapshotExists)
        #expect(try harness.auditEvents() == [.sessionRecovered])
    }

    @Test("recovery without a snapshot does nothing")
    func recoveryWithoutSnapshot() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }

        let recovered = try await harness.controller.recoverIfNeeded()

        #expect(recovered == nil)
        #expect(harness.lid.setCalls.isEmpty)
        #expect(try harness.auditEvents().isEmpty)
    }

    @Test("recovery keeps the snapshot when disablesleep cannot be restored")
    func recoveryRestoreFails() async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sleepDisabled: true))
        defer { harness.cleanUp() }
        harness.lid.failingSetValues = [false]
        try harness.snapshotStore.save(
            SessionSnapshot(
                sessionId: UUID(),
                startedAt: SessionHarness.startDate,
                configuration: SessionConfiguration(keepAwakeWithLidClosed: true),
                previousSleepDisabled: false
            )
        )

        await #expect(throws: ScreenISOError.self) {
            try await harness.controller.recoverIfNeeded()
        }
        #expect(harness.snapshotExists)
        #expect(harness.controller.lastError?.code == "command_failed")
    }

    @Test("a corrupted snapshot is reported, then discarded only on request and audited")
    func discardCorruptedSnapshot() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        try FileManager.default.createDirectory(
            at: harness.snapshotStore.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not json".utf8).write(to: harness.snapshotStore.url)

        await #expect(throws: ScreenISOError.self) {
            try await harness.controller.recoverIfNeeded()
        }
        #expect(harness.controller.lastError?.code == "snapshot_corrupted")
        #expect(harness.snapshotExists)

        try harness.controller.discardSnapshot()

        #expect(!harness.snapshotExists)
        #expect(harness.controller.lastError == nil)
        #expect(harness.lid.setCalls.isEmpty)
        let entry = try #require(try harness.auditEntries().last)
        #expect(entry.event == .snapshotDiscarded)
        #expect(entry.details["previousErrorCode"] == "snapshot_corrupted")
        #expect(try await harness.controller.recoverIfNeeded() == nil)
    }

    @Test("discarding the snapshot is rejected while a session is running")
    func discardDuringSession() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        try await harness.controller.start()

        #expect(throws: ScreenISOError.sessionAlreadyRunning) {
            try harness.controller.discardSnapshot()
        }
        #expect(harness.snapshotExists)
    }

    @Test("a manual change sets disablesleep, audits it and leaves it in place", arguments: [true, false])
    func manualSleepDisabled(target: Bool) async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sleepDisabled: !target))
        defer { harness.cleanUp() }

        try await harness.controller.setSleepDisabled(target)

        #expect(harness.lid.setCalls == [target])
        #expect(harness.lid.sleepDisabled == target)
        #expect(harness.controller.phase == .idle)
        #expect(harness.controller.lastError == nil)
        #expect(!harness.snapshotExists)
        #expect(harness.power.acquireCalls.isEmpty)
        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.sleepDisabledChanged])
        #expect(entries.first?.details["value"] == .bool(target))
        #expect(entries.first?.details["previousValue"] == .bool(!target))
    }

    @Test("a manual change without the sudoers rule changes nothing")
    func manualSleepDisabledWithoutRule() async throws {
        let harness = try SessionHarness(lid: FakeLidSleep(sudoRuleActive: false))
        defer { harness.cleanUp() }

        await #expect(throws: ScreenISOError.sudoRuleMissing) {
            try await harness.controller.setSleepDisabled(true)
        }

        #expect(harness.lid.setCalls.isEmpty)
        #expect(harness.controller.lastError == .sudoRuleMissing)
        #expect(try harness.auditEntries().isEmpty)
    }

    @Test("a manual change is rejected while a session is running")
    func manualSleepDisabledDuringSession() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        try await harness.controller.start()

        await #expect(throws: ScreenISOError.sessionAlreadyRunning) {
            try await harness.controller.setSleepDisabled(true)
        }

        #expect(harness.lid.setCalls.isEmpty)
        #expect(!(try harness.auditEvents()).contains(.sleepDisabledChanged))
    }

    @Test("a session started after a manual change restores the manual value")
    func sessionKeepsManualValue() async throws {
        let harness = try SessionHarness()
        defer { harness.cleanUp() }
        try await harness.controller.setSleepDisabled(true)
        var configuration = SessionConfiguration.default
        configuration.keepAwakeWithLidClosed = true

        try await harness.controller.start(configuration)
        try await harness.controller.end()

        #expect(harness.lid.sleepDisabled)
        #expect(harness.lid.setCalls == [true, true, true])
    }

    private func assertNoSideEffects(_ harness: SessionHarness) {
        #expect(harness.power.acquireCalls.isEmpty)
        #expect(harness.power.heldKinds.isEmpty)
        #expect(harness.lid.setCalls.isEmpty)
        #expect(harness.screen.lockNowCalls == 0)
        #expect(harness.screen.screenSaverCalls == 0)
        #expect(!harness.snapshotExists)
        #expect(harness.events.startCount == 0)
    }
}

extension SessionPhase {
    var isActive: Bool { activeSession != nil }

    var activeSession: ActiveSession? {
        if case .active(let session) = self { session } else { nil }
    }
}
