import Foundation

public enum AuditEvent: String, Codable, CaseIterable, Sendable {
    case sessionStarted = "session_started"
    case sessionStartFailed = "session_start_failed"
    case screenLocked = "screen_locked"
    case screenUnlocked = "screen_unlocked"
    case sessionEnded = "session_ended"
    case sessionRecovered = "session_recovered"
    case snapshotDiscarded = "snapshot_discarded"
    case lockFailed = "lock_failed"
    case preconditionFailed = "precondition_failed"
}

/// A JSON scalar in an audit entry's `details`. Numbers are a single case because JSON does not distinguish 3 from 3.0.
public enum AuditValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try Self.decodeIfType(Bool.self, from: container) {
            self = .bool(value)
        } else if let value = try Self.decodeIfType(Double.self, from: container) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    /// Returns nil when the JSON value is of another type; any other decoding error propagates.
    private static func decodeIfType<T: Decodable>(
        _ type: T.Type,
        from container: any SingleValueDecodingContainer
    ) throws -> T? {
        do {
            return try container.decode(type)
        } catch DecodingError.typeMismatch {
            return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

extension AuditValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
}

public struct AuditEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var event: AuditEvent
    public var sessionId: UUID
    public var details: [String: AuditValue]

    public init(timestamp: Date, event: AuditEvent, sessionId: UUID, details: [String: AuditValue] = [:]) {
        self.timestamp = timestamp
        self.event = event
        self.sessionId = sessionId
        self.details = details
    }

    /// One JSON Lines record, without the trailing newline.
    public func jsonLine() throws -> String {
        let data = try JSONCoding.encoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

public protocol AuditLogging: Sendable {
    func append(_ entry: AuditEntry) throws
}

/// Append-only JSON Lines file. Each record is written with a single `O_APPEND` write and flushed to disk.
public struct FileAuditLog: AuditLogging {
    public static var defaultURL: URL {
        FileLocations.home.appendingPathComponent("Library/Logs/ScreenISO/audit.jsonl")
    }

    public let url: URL

    public init(url: URL = FileAuditLog.defaultURL) {
        self.url = url
    }

    public func append(_ entry: AuditEntry) throws {
        let line: String
        do {
            line = try entry.jsonLine() + "\n"
        } catch {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: error.localizedDescription)
        }

        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }

        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            let reason = written < 0 ? String(cString: strerror(errno)) : "short write \(written)/\(bytes.count)"
            throw ScreenISOError.fileWriteFailed(path: url.path, message: reason)
        }
        guard fsync(descriptor) == 0 else {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: String(cString: strerror(errno)))
        }
        Log.audit.info(
            "audit_entry_written event=\(entry.event.rawValue, privacy: .public) session=\(entry.sessionId.uuidString, privacy: .public)"
        )
    }

    public func entries() throws -> [AuditEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScreenISOError.fileReadFailed(path: url.path, message: error.localizedDescription)
        }
        let decoder = JSONCoding.decoder()
        return try data.split(separator: UInt8(ascii: "\n")).map { line in
            do {
                return try decoder.decode(AuditEntry.self, from: Data(line))
            } catch {
                throw ScreenISOError.fileReadFailed(path: url.path, message: error.localizedDescription)
            }
        }
    }
}
