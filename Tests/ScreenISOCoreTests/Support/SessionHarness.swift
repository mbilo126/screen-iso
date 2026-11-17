import Foundation
import Testing

@testable import ScreenISOCore

@MainActor
final class SessionHarness {
    static let startDate = Date(timeIntervalSince1970: 1_800_000_000)

    let power = FakePowerAssertions()
    let lid: FakeLidSleep
    let policy: FakeLockPolicy
    let screen = FakeScreenLock()
    let events: FakeLockEvents
    let clock: ManualClock
    let directory: TemporaryDirectory
    let auditLog: FileAuditLog
    let snapshotStore: FileSessionSnapshotStore
    let controller: SessionController

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
        snapshotStore = FileSessionSnapshotStore(url: directory.file("Support/session.json"))
        let clock = ManualClock(SessionHarness.startDate)
        self.clock = clock
        controller = SessionController(
            powerAssertions: power,
            lidSleep: lid,
            lockPolicy: policy,
            screenLock: screen,
            lockEvents: events,
            auditLog: auditLog,
            snapshotStore: snapshotStore,
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

    var snapshotExists: Bool {
        FileManager.default.fileExists(atPath: snapshotStore.url.path)
    }

    func cleanUp() {
        do {
            try directory.remove()
        } catch {
            Issue.record(error, "Could not remove \(directory.url.path)")
        }
    }
}
