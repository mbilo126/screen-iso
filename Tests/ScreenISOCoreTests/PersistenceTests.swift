import Foundation
import Testing

@testable import ScreenISOCore

@Suite("Audit log")
struct AuditLogTests {
    static let sessionId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)

    @Test("line format")
    func lineFormat() throws {
        let entry = AuditEntry(
            timestamp: Self.timestamp,
            event: .sessionEnded,
            sessionId: Self.sessionId,
            details: ["trigger": "screenUnlocked", "durationSeconds": 3600.5, "cleanupComplete": true, "attempts": 2]
        )
        #expect(
            try entry.jsonLine()
                == #"{"details":{"attempts":2,"cleanupComplete":true,"durationSeconds":3600.5,"trigger":"screenUnlocked"},"#
                + #""event":"session_ended","sessionId":"6F9619FF-8B86-D011-B42D-00C04FC964FF","#
                + #""timestamp":"2027-01-15T08:00:00.250Z"}"#
        )
    }

    @Test("event names are snake_case")
    func eventNames() {
        #expect(
            AuditEvent.allCases.map(\.rawValue) == [
                "session_started", "session_start_failed", "screen_locked", "screen_unlocked", "session_ended",
                "session_recovered", "snapshot_discarded", "lock_failed", "precondition_failed",
            ])
    }

    @Test("appends one JSON object per line and reads them back")
    func appendAndRead() throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let log = FileAuditLog(url: directory.file("nested/Logs/audit.jsonl"))
        let first = AuditEntry(timestamp: Self.timestamp, event: .sessionStarted, sessionId: Self.sessionId)
        let second = AuditEntry(
            timestamp: Self.timestamp.addingTimeInterval(1),
            event: .screenLocked,
            sessionId: Self.sessionId,
            details: ["lockMethod": "loginWindow"]
        )

        try log.append(first)
        try log.append(second)

        let text = try String(contentsOf: log.url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines.last == "")
        for line in lines.dropLast() {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(Set(object?.keys.map { $0 } ?? []) == ["timestamp", "event", "sessionId", "details"])
        }
        #expect(try log.entries() == [first, second])

        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("detail values keep their JSON type")
    func detailValueTypes() throws {
        let data = Data(#"{"a":true,"b":3,"c":1.5,"d":"x"}"#.utf8)
        let values = try JSONDecoder().decode([String: AuditValue].self, from: data)
        #expect(values == ["a": .bool(true), "b": .number(3), "c": .number(1.5), "d": .string("x")])
    }

    private func removeDirectory(_ directory: TemporaryDirectory) {
        do {
            try directory.remove()
        } catch {
            Issue.record(error)
        }
    }
}

@Suite("Session snapshot")
struct SessionSnapshotTests {
    @Test("saves, loads and deletes")
    func roundTrip() throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = FileSessionSnapshotStore(url: directory.file("Application Support/ScreenISO/session.json"))
        let snapshot = SessionSnapshot(
            sessionId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            configuration: SessionConfiguration(
                powerAssertions: [.preventDisplaySleep, .preventIdleSystemSleep],
                keepAwakeWithLidClosed: true,
                lockMode: .screenSaver
            ),
            previousSleepDisabled: true
        )

        #expect(try store.load() == nil)
        try store.save(snapshot)
        #expect(try store.load() == snapshot)

        let json = try String(contentsOf: store.url, encoding: .utf8)
        #expect(json.contains(#""startedAt":"2027-01-15T08:00:00.000Z""#))
        #expect(json.contains(#""powerAssertions":["preventIdleSystemSleep","preventDisplaySleep"]"#))
        #expect(json.contains(#""previousSleepDisabled":true"#))

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    @Test("a corrupted snapshot fails loud")
    func corrupted() throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = FileSessionSnapshotStore(url: directory.file("session.json"))
        try Data("{not json".utf8).write(to: store.url)

        #expect {
            try store.load()
        } throws: { error in
            (error as? ScreenISOError)?.code == "snapshot_corrupted"
        }
    }

    private func removeDirectory(_ directory: TemporaryDirectory) {
        do {
            try directory.remove()
        } catch {
            Issue.record(error)
        }
    }
}

@Suite("Session configuration")
struct SessionConfigurationTests {
    @Test("defaults")
    func defaults() {
        let configuration = SessionConfiguration.default
        #expect(configuration.powerAssertions == [.preventIdleSystemSleep, .preventSystemSleep])
        #expect(configuration.keepAwakeWithLidClosed == false)
        #expect(configuration.lockMode == .loginWindow)
    }

    @Test("JSON round trip with camelCase keys")
    func codable() throws {
        let data = try JSONCoding.encoder().encode(SessionConfiguration.default)
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"keepAwakeWithLidClosed":false,"lockMode":"loginWindow","powerAssertions":["preventIdleSystemSleep","preventSystemSleep"]}"#
        )
        #expect(try JSONCoding.decoder().decode(SessionConfiguration.self, from: data) == .default)
    }
}
