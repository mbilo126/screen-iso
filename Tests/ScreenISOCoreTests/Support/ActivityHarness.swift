import Foundation
import Testing

@testable import ScreenISOCore

@MainActor
final class ActivityHarness {
    static let startDate = Date(timeIntervalSince1970: 1_800_000_000)

    let power = FakePowerAssertions()
    let lid: FakeLidSleep
    let policy: FakeLockPolicy
    let screen = FakeScreenLock()
    let events: FakeLockEvents
    let clock: ManualClock
    let directory: TemporaryDirectory
    let auditLog: FileAuditLog
    let controller: ActivityController

    init(
        lid: FakeLidSleep = FakeLidSleep(),
        policy: FakeLockPolicy = FakeLockPolicy(),
        events: FakeLockEvents = FakeLockEvents(),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) throws {
        self.lid = lid
        self.policy = policy
        self.events = events
        directory = try TemporaryDirectory()
        auditLog = FileAuditLog(url: directory.file("Logs/audit.jsonl"))
        let clock = ManualClock(ActivityHarness.startDate)
        self.clock = clock
        controller = ActivityController(
            powerAssertions: power,
            lidSleep: lid,
            lockPolicy: policy,
            screenLock: screen,
            lockEvents: events,
            auditLog: auditLog,
            now: { clock.now() },
            sleep: sleep ?? { _ in clock.advance(by: 0.25) }
        )
    }

    func auditEntries() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: auditLog.url.path) else { return [] }
        return try auditLog.entries()
    }

    func auditEvents() throws -> [AuditEvent] {
        try auditEntries().map(\.event)
    }

    /// Puts a regular file where the log directory should be, so every audit write fails.
    func breakAuditLog() throws {
        try Data().write(to: auditLog.url.deletingLastPathComponent())
    }

    func cleanUp() {
        do {
            try directory.remove()
        } catch {
            Issue.record(error, "Could not remove \(directory.url.path)")
        }
    }
}
