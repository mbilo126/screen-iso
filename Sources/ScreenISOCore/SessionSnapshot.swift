import Foundation

/// Written before any system change so a crashed session can be undone at the next launch.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: UUID
    public var startedAt: Date
    public var configuration: SessionConfiguration
    public var previousSleepDisabled: Bool

    public init(sessionId: UUID, startedAt: Date, configuration: SessionConfiguration, previousSleepDisabled: Bool) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.configuration = configuration
        self.previousSleepDisabled = previousSleepDisabled
    }
}

public protocol SessionSnapshotStoring: Sendable {
    func save(_ snapshot: SessionSnapshot) throws
    /// Returns nil only when no snapshot file exists; an unreadable file throws.
    func load() throws -> SessionSnapshot?
    func delete() throws
}

public struct FileSessionSnapshotStore: SessionSnapshotStoring {
    public static var defaultURL: URL {
        FileLocations.home.appendingPathComponent("Library/Application Support/ScreenISO/session.json")
    }

    public let url: URL

    public init(url: URL = FileSessionSnapshotStore.defaultURL) {
        self.url = url
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONCoding.encoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: error.localizedDescription)
        }
    }

    public func load() throws -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScreenISOError.fileReadFailed(path: url.path, message: error.localizedDescription)
        }
        do {
            return try JSONCoding.decoder().decode(SessionSnapshot.self, from: data)
        } catch {
            throw ScreenISOError.snapshotCorrupted(path: url.path, message: String(describing: error))
        }
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ScreenISOError.fileWriteFailed(path: url.path, message: error.localizedDescription)
        }
    }
}
