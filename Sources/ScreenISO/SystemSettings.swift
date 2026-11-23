import AppKit
import Foundation

enum SystemSettings {
    @MainActor
    static func open(_ url: String) throws {
        guard let target = URL(string: url), NSWorkspace.shared.open(target) else {
            AppLog.app.error("settings_open_failed url=\(url, privacy: .public)")
            throw AppError.settingsOpenFailed(url: url)
        }
    }
}

/// The pane where macOS sets how soon the password is asked once the screen saver starts or the display turns off.
/// ScreenISO only opens it: changing the value would take the login password, which stays with System Settings.
enum LockScreenSettingsPane {
    static let url = "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    static let openButtonTitle = "Apri Impostazioni Schermata di blocco"
    static let hint =
        "In Impostazioni di Sistema apri Schermata di blocco e imposta su \"Immediatamente\" la richiesta della password dopo l'avvio del salvaschermo o lo spegnimento dello schermo."
}
