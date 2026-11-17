import Foundation
import ScreenISOCore

@MainActor
protocol DataDefaults: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: DataDefaults {}

/// Persists `SessionConfiguration` as JSON in `UserDefaults`.
@MainActor
final class ConfigurationStore {
    static let key = "sessionConfiguration"

    private let defaults: any DataDefaults

    init(defaults: any DataDefaults = UserDefaults.standard) {
        self.defaults = defaults
    }

    /// Returns the default configuration only when nothing was ever saved; unreadable data throws.
    func load() throws -> SessionConfiguration {
        guard let data = defaults.data(forKey: Self.key) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(SessionConfiguration.self, from: data)
        } catch {
            AppLog.configuration.error(
                "configuration_decode_failed error=\(String(describing: error), privacy: .public)"
            )
            throw AppError.configurationUnreadable(message: String(describing: error))
        }
    }

    func save(_ configuration: SessionConfiguration) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(configuration)
        } catch {
            throw AppError.configurationWriteFailed(message: String(describing: error))
        }
        defaults.set(data, forKey: Self.key)
        AppLog.configuration.info("configuration_saved")
    }
}
