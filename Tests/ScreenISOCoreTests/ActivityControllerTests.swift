import Foundation
import Testing

@testable import ScreenISOCore

@MainActor
@Suite("ActivityController activities")
struct ActivityControllerActivityTests {
    @Test("assertions are acquired one at a time and each change is audited")
    func acquire() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }

        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)

        #expect(harness.power.acquireCalls == [.preventIdleSystemSleep, .preventDisplaySleep])
        #expect(harness.power.heldKinds == [.preventDisplaySleep, .preventIdleSystemSleep])
        #expect(harness.controller.activeAssertions == [.preventDisplaySleep, .preventIdleSystemSleep])
        #expect(harness.controller.lastError == nil)

        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.powerAssertionChanged, .powerAssertionChanged])
        #expect(Set(entries.map(\.sessionId)).count == 2)
        let last = try #require(entries.last)
        #expect(last.details["kind"] == "preventDisplaySleep")
        #expect(last.details["caffeinateFlag"] == "-d")
        #expect(last.details["value"] == true)
        #expect(last.details["powerAssertions"] == "preventDisplaySleep,preventIdleSystemSleep")
    }

    @Test("switching one assertion off leaves the others held")
    func release() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventSystemSleep, active: true)
        try harness.controller.setAssertion(.userIsActive, active: true)

        try harness.controller.setAssertion(.preventSystemSleep, active: false)

        #expect(harness.power.releaseCalls == [.preventSystemSleep])
        #expect(harness.controller.activeAssertions == [.userIsActive])
        let last = try #require(try harness.auditEntries().last)
        #expect(last.details["value"] == false)
        #expect(last.details["caffeinateFlag"] == "-s")
        #expect(last.details["powerAssertions"] == "userIsActive")
    }

    @Test("asking for the current value does nothing")
    func unchanged() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventDiskIdle, active: true)

        try harness.controller.setAssertion(.preventDiskIdle, active: true)
        try harness.controller.setAssertion(.preventDisplaySleep, active: false)

        #expect(harness.power.acquireCalls == [.preventDiskIdle])
        #expect(harness.power.releaseCalls.isEmpty)
        #expect(try harness.auditEvents() == [.powerAssertionChanged])
    }

    @Test("a failure acquiring is thrown, kept for the panel and not audited")
    func acquireFailure() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        let failure = ScreenISOError.powerAssertionCreateFailed(kind: .preventSystemSleep, ioReturn: -536_870_212)
        harness.power.acquireError = failure

        #expect(throws: failure) {
            try harness.controller.setAssertion(.preventSystemSleep, active: true)
        }

        #expect(harness.controller.activeAssertions.isEmpty)
        #expect(harness.controller.lastError == failure)
        #expect(try harness.auditEntries().isEmpty)
    }

    @Test("a failure releasing is thrown and the assertion is no longer shown as active")
    func releaseFailure() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)
        harness.power.failingReleases = [.preventDisplaySleep]

        #expect(throws: ScreenISOError.powerAssertionReleaseFailed(kind: .preventDisplaySleep, ioReturn: -1)) {
            try harness.controller.setAssertion(.preventDisplaySleep, active: false)
        }

        #expect(harness.controller.activeAssertions.isEmpty)
        #expect(harness.controller.lastError?.code == "power_assertion_release_failed")
        #expect(try harness.auditEvents() == [.powerAssertionChanged])
    }

    @Test("an audit failure is thrown and the panel still shows what is really held")
    func auditFailure() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.breakAuditLog()

        #expect {
            try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        } throws: { error in
            (error as? ScreenISOError)?.code == "file_write_failed"
        }

        #expect(harness.power.heldKinds == [.preventIdleSystemSleep])
        #expect(harness.controller.activeAssertions == [.preventIdleSystemSleep])
        #expect(harness.controller.lastError?.code == "file_write_failed")
    }

    @Test("select all acquires only the missing assertions and audits each of them")
    func selectAll() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventSystemSleep, active: true)

        try harness.controller.setAllAssertions(active: true)

        #expect(
            harness.power.acquireCalls == [
                .preventSystemSleep, .preventDisplaySleep, .preventIdleSystemSleep, .preventDiskIdle, .userIsActive,
            ])
        #expect(harness.controller.activeAssertions == Set(PowerAssertionKind.allCases))
        let entries = try harness.auditEntries()
        #expect(entries.count == 5)
        #expect(entries.allSatisfy { $0.event == .powerAssertionChanged && $0.details["value"] == true })
        #expect(
            entries.last?.details["powerAssertions"]
                == "preventDisplaySleep,preventIdleSystemSleep,preventSystemSleep,preventDiskIdle,userIsActive")

        try harness.controller.setAllAssertions(active: true)
        #expect(try harness.auditEntries().count == 5)
    }

    @Test("select all tries every assertion and reports the ones that failed")
    func selectAllFailure() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        harness.power.failingAcquires = [.preventSystemSleep, .userIsActive]

        do {
            try harness.controller.setAllAssertions(active: true)
            Issue.record("setAllAssertions should have thrown")
        } catch let error as ScreenISOError {
            guard case .multipleFailures(let errors) = error else {
                Issue.record("Expected multiple_failures, got \(error.code)")
                return
            }
            #expect(errors.map(\.code) == ["power_assertion_create_failed", "power_assertion_create_failed"])
        }

        #expect(
            harness.controller.activeAssertions == [.preventDisplaySleep, .preventIdleSystemSleep, .preventDiskIdle])
        #expect(harness.controller.lastError?.code == "multiple_failures")
        #expect(try harness.auditEntries().count == 3)
    }

    @Test("deselecting everything, as on quit, audits each assertion")
    func releaseAll() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)

        try harness.controller.setAllAssertions(active: false)

        #expect(harness.power.releaseCalls == [.preventDisplaySleep, .preventIdleSystemSleep])
        #expect(harness.controller.activeAssertions.isEmpty)
        let entries = try harness.auditEntries()
        #expect(entries.count == 4)
        #expect(entries.suffix(2).allSatisfy { $0.details["value"] == false })
        #expect(entries.last?.details["powerAssertions"] == "")
    }

    @Test("a failure while releasing everything is reported once and does not block a second attempt")
    func releaseAllFailure() throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)
        harness.power.failingReleases = [.preventDisplaySleep]

        #expect(throws: ScreenISOError.powerAssertionReleaseFailed(kind: .preventDisplaySleep, ioReturn: -1)) {
            try harness.controller.setAllAssertions(active: false)
        }
        #expect(harness.controller.activeAssertions.isEmpty)
        #expect(harness.controller.lastError?.code == "power_assertion_release_failed")

        try harness.controller.setAllAssertions(active: false)
        #expect(harness.controller.lastError == nil)
    }

    @Test("a manual change sets disablesleep, audits it and leaves it in place", arguments: [true, false])
    func sleepDisabled(target: Bool) async throws {
        let harness = try ActivityHarness(lid: FakeLidSleep(sleepDisabled: !target))
        defer { harness.cleanUp() }

        try await harness.controller.setSleepDisabled(target)

        #expect(harness.lid.setCalls == [target])
        #expect(harness.lid.sleepDisabled == target)
        #expect(harness.controller.lastError == nil)
        #expect(harness.power.acquireCalls.isEmpty)
        let entries = try harness.auditEntries()
        #expect(entries.map(\.event) == [.sleepDisabledChanged])
        #expect(entries.first?.details["value"] == .bool(target))
        #expect(entries.first?.details["previousValue"] == .bool(!target))
    }

    @Test("a manual change without the sudoers rule changes nothing")
    func sleepDisabledWithoutRule() async throws {
        let harness = try ActivityHarness(lid: FakeLidSleep(sudoRuleActive: false))
        defer { harness.cleanUp() }

        await #expect(throws: ScreenISOError.sudoRuleMissing) {
            try await harness.controller.setSleepDisabled(true)
        }

        #expect(harness.lid.setCalls.isEmpty)
        #expect(harness.controller.lastError == .sudoRuleMissing)
        #expect(try harness.auditEntries().isEmpty)
    }
}

@MainActor
@Suite("ActivityController lock")
struct ActivityControllerLockTests {
    @Test("locking and unlocking leave every activity exactly as it was")
    func activitiesSurviveLock() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)
        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        try await harness.controller.setSleepDisabled(true)

        try await harness.controller.lock(.loginWindow)

        let lock = try #require(harness.controller.lockPhase.activeLock)
        #expect(lock.method == .loginWindow)
        #expect(lock.mode == .loginWindow)
        #expect(lock.lockedAt == ActivityHarness.startDate)
        #expect(harness.screen.lockNowCalls == 1)
        #expect(harness.screen.screenSaverCalls == 0)
        #expect(harness.events.isObserving)
        #expect(harness.controller.lastError == nil)

        harness.clock.advance(by: 3600)
        await harness.events.emit(.unlocked)

        #expect(harness.controller.lockPhase == .unlocked)
        #expect(!harness.events.isObserving)
        #expect(harness.controller.activeAssertions == [.preventDisplaySleep, .preventIdleSystemSleep])
        #expect(harness.power.heldKinds == [.preventDisplaySleep, .preventIdleSystemSleep])
        #expect(harness.power.releaseCalls.isEmpty)
        #expect(harness.lid.setCalls == [true])
        #expect(harness.lid.sleepDisabled)

        let entries = try harness.auditEntries().suffix(2)
        #expect(entries.map(\.event) == [.screenLocked, .screenUnlocked])
        #expect(Set(entries.map(\.sessionId)) == [lock.lockId])
        let locked = try #require(entries.first)
        #expect(locked.details["lockMode"] == "loginWindow")
        #expect(locked.details["lockMethod"] == "loginWindow")
        #expect(locked.details["powerAssertions"] == "preventDisplaySleep,preventIdleSystemSleep")
        #expect(locked.details["sleepDisabled"] == true)
        #expect(locked.details["screenLockPolicy"] == "screenLock delay is immediate")
        let unlocked = try #require(entries.last)
        #expect(unlocked.details["lockedDurationSeconds"] == 3600)
        #expect(unlocked.details["powerAssertions"] == "preventDisplaySleep,preventIdleSystemSleep")
    }

    @Test("the screen can be locked with no activity on")
    func lockWithoutActivities() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }

        try await harness.controller.lock(.loginWindow)

        #expect(harness.controller.lockPhase.activeLock != nil)
        #expect(harness.power.acquireCalls.isEmpty)
        #expect(harness.lid.setCalls.isEmpty)
        let locked = try #require(try harness.auditEntries().last)
        #expect(locked.details["powerAssertions"] == "")
        #expect(locked.details["sleepDisabled"] == false)
    }

    @Test("an activity can be switched off while the screen is locked")
    func changeWhileLocked() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventDisplaySleep, active: true)
        try await harness.controller.lock(.loginWindow)

        try harness.controller.setAssertion(.preventDisplaySleep, active: false)

        #expect(harness.controller.activeAssertions.isEmpty)
        #expect(harness.controller.lockPhase.activeLock != nil)
    }

    @Test("a non immediate screen lock policy fails before any side effect")
    func preconditionPolicy() async throws {
        let harness = try ActivityHarness(
            policy: FakeLockPolicy(.delay(seconds: 300), raw: "screenLock delay is 300 seconds"))
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)

        await #expect(throws: ScreenISOError.screenLockNotImmediate(.delay(seconds: 300))) {
            try await harness.controller.lock(.screenSaver)
        }

        #expect(harness.screen.lockNowCalls == 0)
        #expect(harness.screen.screenSaverCalls == 0)
        #expect(harness.events.startCount == 0)
        #expect(harness.controller.lockPhase == .unlocked)
        #expect(harness.controller.lastError?.code == "screen_lock_not_immediate")
        #expect(harness.controller.activeAssertions == [.preventIdleSystemSleep])
        let failed = try #require(try harness.auditEntries().last)
        #expect(failed.event == .preconditionFailed)
        #expect(failed.details["errorCode"] == "screen_lock_not_immediate")
        #expect(failed.details["lockMode"] == "screenSaver")
    }

    @Test("an unconfirmed lock is reported and leaves the activities alone")
    func lockNotConfirmed() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.controller.setAssertion(.preventIdleSystemSleep, active: true)
        harness.screen.lockNowLocks = false

        await #expect(throws: ScreenISOError.lockNotConfirmed(lockMode: .loginWindow)) {
            try await harness.controller.lock(.loginWindow)
        }

        #expect(harness.controller.lockPhase == .unlocked)
        #expect(!harness.events.isObserving)
        #expect(harness.controller.activeAssertions == [.preventIdleSystemSleep])
        #expect(harness.power.releaseCalls.isEmpty)
        // 5 s at 250 ms: one check per wait plus the initial one.
        #expect(harness.screen.lockChecks == 21)
        #expect(harness.clock.now() == ActivityHarness.startDate.addingTimeInterval(5))

        let failed = try #require(try harness.auditEntries().last)
        #expect(failed.event == .lockFailed)
        #expect(failed.details["errorCode"] == "lock_not_confirmed")
        #expect(failed.details["lockMode"] == "loginWindow")
    }

    @Test("a missing lock symbol is reported")
    func lockSymbolMissing() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        let symbolError = ScreenISOError.lockSymbolUnavailable(detail: "symbol not found")
        harness.screen.symbolError = symbolError

        await #expect(throws: symbolError) {
            try await harness.controller.lock(.loginWindow)
        }

        #expect(harness.controller.lockPhase == .unlocked)
        #expect(try harness.auditEvents() == [.lockFailed])
    }

    @Test("screen saver mode does not call lockNow when the saver locks")
    func screenSaverLocks() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }

        try await harness.controller.lock(.screenSaver)

        #expect(harness.screen.screenSaverCalls == 1)
        #expect(harness.screen.lockNowCalls == 0)
        #expect(harness.controller.lockPhase.activeLock?.method == .screenSaver)
        #expect(harness.controller.lockPhase.activeLock?.mode == .screenSaver)
    }

    @Test("screen saver mode falls back to lockNow when the saver does not lock")
    func screenSaverFallback() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverLocks = false

        try await harness.controller.lock(.screenSaver)

        #expect(harness.controller.lockPhase.activeLock?.method == .loginWindowFallback)
        #expect(harness.screen.screenSaverCalls == 1)
        #expect(harness.screen.lockNowCalls == 1)
        let locked = try #require(try harness.auditEntries().last)
        #expect(locked.event == .screenLocked)
        #expect(locked.details["lockMethod"] == "loginWindowFallback")
    }

    @Test("screen saver mode falls back to lockNow when the saver cannot start")
    func screenSaverLaunchFallback() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverError = .screenSaverLaunchFailed(message: "not found")

        try await harness.controller.lock(.screenSaver)

        #expect(harness.screen.lockNowCalls == 1)
        #expect(harness.controller.lockPhase.activeLock?.method == .loginWindowFallback)
    }

    @Test("screen saver mode fails when neither the saver nor lockNow lock")
    func screenSaverAndFallbackFail() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        harness.screen.screenSaverLocks = false
        harness.screen.lockNowLocks = false

        await #expect(throws: ScreenISOError.lockNotConfirmed(lockMode: .screenSaver)) {
            try await harness.controller.lock(.screenSaver)
        }
        #expect(harness.screen.lockChecks == 42)
        #expect(harness.controller.lockPhase == .unlocked)
    }

    @Test("a lock notification confirms the lock even if the session flag lags")
    func lockNotificationConfirms() async throws {
        let events = FakeLockEvents()
        let harness = try ActivityHarness(events: events, sleep: { _ in await events.emit(.locked) })
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false

        try await harness.controller.lock(.loginWindow)

        #expect(harness.controller.lockPhase.activeLock != nil)
    }

    @Test("an unlock received while locking is recorded as soon as the lock is confirmed")
    func unlockWhileLocking() async throws {
        let events = FakeLockEvents()
        let harness = try ActivityHarness(
            events: events,
            sleep: { _ in
                await events.emit(.locked)
                await events.emit(.unlocked)
            }
        )
        defer { harness.cleanUp() }
        harness.screen.lockNowLocks = false

        try await harness.controller.lock(.loginWindow)

        #expect(harness.controller.lockPhase == .unlocked)
        #expect(!harness.events.isObserving)
        #expect(try harness.auditEvents() == [.screenLocked, .screenUnlocked])
    }

    @Test("a second lock is rejected while one is in place, and allowed again after the unlock")
    func lockTwice() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try await harness.controller.lock(.loginWindow)
        let first = try #require(harness.controller.lockPhase.activeLock)

        await #expect(throws: ScreenISOError.lockAlreadyInProgress) {
            try await harness.controller.lock(.screenSaver)
        }
        #expect(harness.screen.lockNowCalls == 1)
        #expect(harness.screen.screenSaverCalls == 0)

        await harness.events.emit(.unlocked)
        harness.screen.locked = false
        try await harness.controller.lock(.screenSaver)

        let second = try #require(harness.controller.lockPhase.activeLock)
        #expect(second.lockId != first.lockId)
        #expect(second.method == .screenSaver)
    }

    @Test("an audit failure after the lock is kept for the panel, the screen stays locked")
    func auditFailureAfterLock() async throws {
        let harness = try ActivityHarness()
        defer { harness.cleanUp() }
        try harness.breakAuditLog()

        try await harness.controller.lock(.loginWindow)

        #expect(harness.controller.lockPhase.activeLock != nil)
        #expect(harness.controller.lastError?.code == "file_write_failed")
    }
}

extension LockPhase {
    var activeLock: ActiveLock? {
        if case .locked(let lock) = self { lock } else { nil }
    }
}
