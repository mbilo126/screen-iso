import Foundation
import ScreenISOCore

/// Failures of the app layer: configuration, bundled resources and Finder or System Settings hand-offs.
enum AppError: Error, Equatable, Sendable {
    case configurationUnreadable(message: String)
    case configurationWriteFailed(message: String)
    case saverResourceMissing
    case saverInstallFailed(message: String)
    case saverHostReloadFailed(message: String)
    case settingsOpenFailed(url: String)
    case auditLogMissing(path: String)

    var code: String {
        switch self {
        case .configurationUnreadable: "configuration_unreadable"
        case .configurationWriteFailed: "configuration_write_failed"
        case .saverResourceMissing: "saver_resource_missing"
        case .saverInstallFailed: "saver_install_failed"
        case .saverHostReloadFailed: "saver_host_reload_failed"
        case .settingsOpenFailed: "settings_open_failed"
        case .auditLogMissing: "audit_log_missing"
        }
    }

    var detail: String {
        switch self {
        case .configurationUnreadable(let message), .configurationWriteFailed(let message),
            .saverInstallFailed(let message), .saverHostReloadFailed(let message):
            message
        case .saverResourceMissing:
            "ScreenISOSaver.saver not found in the app bundle"
        case .settingsOpenFailed(let url):
            url
        case .auditLogMissing(let path):
            path
        }
    }
}

/// An error ready for the panel: the stable code plus an Italian message.
struct DisplayedError: Equatable, Sendable {
    var code: String
    var message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: ScreenISOError) {
        self.init(code: error.code, message: ErrorMessages.message(for: error))
    }

    init(_ error: AppError) {
        self.init(code: error.code, message: ErrorMessages.message(for: error))
    }

    init(_ error: any Error) {
        if let error = error as? AppError {
            self.init(error)
        } else {
            self.init(ScreenISOError(error))
        }
    }
}
