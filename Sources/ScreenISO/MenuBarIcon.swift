import AppKit
import Foundation

protocol MenuBarPositionStoring {
    func set(_ value: Double, forKey defaultName: String)
}

extension UserDefaults: MenuBarPositionStoring {}

/// The icon in the menu bar. A new icon goes to the left of the others, and when the bar is full macOS stops
/// drawing the leftmost ones: on a Mac with a notch the icon of a freshly installed app can be invisible.
@MainActor
struct MenuBarIcon {
    /// AppKit reads the position only when it creates the status item, and SwiftUI names the item of the first
    /// `MenuBarExtra` `Item-0`. Checked on macOS 26.6: with this value the icon sits next to the system ones.
    nonisolated static let positionKey = "NSStatusItem Preferred Position Item-0"
    nonisolated static let positionNextToSystemIcons = 1.0
    nonisolated static let statusWindowClassName = "NSStatusBarWindow"

    var store: any MenuBarPositionStoring = UserDefaults.standard

    /// True when the icon exists but macOS is not drawing it. Without a status item there is nothing to report.
    var isHidden: Bool {
        guard let window = NSApp.windows.first(where: { $0.className == Self.statusWindowClassName }) else {
            return false
        }
        return !window.occlusionState.contains(.visible)
    }

    /// Takes effect the next time the app starts.
    func savePositionNextToSystemIcons() {
        store.set(Self.positionNextToSystemIcons, forKey: Self.positionKey)
        AppLog.app.info("menu_bar_position_saved")
    }
}

/// Starts a second copy of the app. The caller quits the running one once the new copy is up.
@MainActor
struct AppRelauncher {
    var bundleURL: URL = Bundle.main.bundleURL

    func launchNewInstance() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let url = bundleURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: AppError.relaunchFailed(message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
