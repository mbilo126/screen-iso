import Foundation
import ScreenISOCore

/// Where the screen saver is chosen. macOS 26 folded the Screen Saver pane into Wallpaper, behind a button.
enum ScreenSaverSettingsPane: Equatable, Sendable {
    case wallpaper
    case screenSaver

    static var current: ScreenSaverSettingsPane {
        ScreenSaverSettingsPane(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    init(osMajorVersion: Int) {
        self = osMajorVersion >= 26 ? .wallpaper : .screenSaver
    }

    var url: String {
        switch self {
        case .wallpaper: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
        case .screenSaver: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
        }
    }

    var openButtonTitle: String {
        switch self {
        case .wallpaper: "Apri Impostazioni Sfondo"
        case .screenSaver: "Apri Impostazioni Salvaschermo"
        }
    }

    var selectionHint: String {
        switch self {
        case .wallpaper:
            "In Impostazioni di Sistema apri Sfondo, premi \"Salvaschermo…\" e scegli ScreenISO nella sezione Altro."
        case .screenSaver:
            "In Impostazioni di Sistema apri Salvaschermo e scegli ScreenISO nella sezione Altro."
        }
    }
}

/// Copies the bundled `.saver` to the user's Screen Savers folder and opens the settings pane that selects it.
@MainActor
struct ScreenSaverInstaller {
    nonisolated static let resourceName = "ScreenISOSaver"
    nonisolated static let hostProcessName = "legacyScreenSaver"
    nonisolated static let pkillPath = "/usr/bin/pkill"

    var bundle: Bundle = .main
    var destination: URL = SystemStatusReader.defaultScreenSaverURL
    var pane: ScreenSaverSettingsPane = .current
    var runner: any CommandRunning = ProcessCommandRunner()

    nonisolated static func hostReloadArguments(userID: uid_t = getuid()) -> [String] {
        ["-U", String(userID), "-x", hostProcessName]
    }

    func bundledSaverURL() throws -> URL {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "saver") else {
            throw AppError.saverResourceMissing
        }
        return url
    }

    /// False when the installed copy differs from the one bundled with this build of the app.
    func isInstalledCopyCurrent() throws -> Bool {
        let source = try bundledSaverURL()
        return FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path)
    }

    /// Installs the bundled saver. An older copy is replaced and the host is restarted so it loads the new code.
    func install() async throws {
        let source = try bundledSaverURL()
        let folder = destination.deletingLastPathComponent()
        // Not a `.saver` name, so the system never lists the half-copied bundle.
        let staged = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        let replacing = FileManager.default.fileExists(atPath: destination.path)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: staged)
            if replacing {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            AppLog.app.error("saver_install_failed error=\(error.localizedDescription, privacy: .public)")
            removeStagedCopy(staged)
            throw AppError.saverInstallFailed(message: error.localizedDescription)
        }
        AppLog.app.info("saver_installed path=\(destination.path, privacy: .public) replaced=\(replacing)")
        if replacing {
            try await reloadHost()
        }
    }

    /// The host process keeps the previous code loaded until it exits; macOS starts a new one on demand.
    func reloadHost() async throws {
        let output = try await runner.run(Self.pkillPath, arguments: Self.hostReloadArguments())
        // pkill exits with 1 when no process matched, which is fine: there was nothing to reload.
        guard output.exitCode == 0 || output.exitCode == 1 else {
            AppLog.app.error("saver_host_reload_failed stderr=\(output.stderr, privacy: .public)")
            throw AppError.saverHostReloadFailed(message: output.stderr)
        }
        AppLog.app.info("saver_host_reloaded matched=\(output.exitCode == 0)")
    }

    func openSettings() throws {
        try SystemSettings.open(pane.url)
    }

    private func removeStagedCopy(_ staged: URL) {
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        do {
            try FileManager.default.removeItem(at: staged)
        } catch {
            AppLog.app.error("saver_staged_cleanup_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
