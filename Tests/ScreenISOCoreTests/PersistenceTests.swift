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
                "power_assertion_changed", "sleep_disabled_changed", "screen_locked", "screen_unlocked", "lock_failed",
                "precondition_failed", "session_started", "session_start_failed", "session_ended",
                "session_recovered", "snapshot_discarded",
            ])
    }

    @Test("records written by earlier versions still decode")
    func legacyRecords() throws {
        let line =
            #"{"details":{"cleanupComplete":true,"trigger":"screenUnlocked"},"event":"session_ended","#
            + #""sessionId":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2027-01-15T08:00:00.250Z"}"#
        let entry = try JSONCoding.decoder().decode(AuditEntry.self, from: Data(line.utf8))
        #expect(entry.event == .sessionEnded)
        #expect(entry.sessionId == Self.sessionId)
        #expect(entry.details["trigger"] == "screenUnlocked")
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
