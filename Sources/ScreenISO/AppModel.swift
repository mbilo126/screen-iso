import AppKit
import Foundation
import Observation
import ScreenISOCore

@MainActor
@Observable
final class AppModel {
    static let updateCheckInterval: Duration = .seconds(86_400)

    let controller: ActivityController

    private(set) var status: SystemStatus?
    private(set) var statusError: DisplayedError?
    private(set) var isLoadingStatus = false

    private(set) var actionError: DisplayedError?
    private(set) var busyAction: String?
    private(set) var saverNeedsUpdate = false
    /// The value just requested from the SleepDisabled switch, shown until the system status is read again.
    private(set) var pendingSleepDisabled: Bool?
    private(set) var menuBarIconHidden = false
    private(set) var availableUpdate: AppVersion?

    @ObservationIgnored private let statusReader: SystemStatusReader
    @ObservationIgnored private let sudoersInstaller: any SudoersRuleInstalling
    @ObservationIgnored private let saverInstaller: ScreenSaverInstaller
    @ObservationIgnored private let menuBarIcon: MenuBarIcon
    @ObservationIgnored private let relauncher: AppRelauncher
    @ObservationIgnored private let updater: AppUpdater
    @ObservationIgnored private var launched = false

    init(
        controller: ActivityController = .live(),
        statusReader: SystemStatusReader = .live(),
        sudoersInstaller: any SudoersRuleInstalling = AppleScriptSudoersInstaller(),
        saverInstaller: ScreenSaverInstaller = ScreenSaverInstaller(),
        menuBarIcon: MenuBarIcon = MenuBarIcon(),
        relauncher: AppRelauncher = AppRelauncher(),
        updater: AppUpdater = AppUpdater()
    ) {
        self.controller = controller
        self.statusReader = statusReader
        self.sudoersInstaller = sudoersInstaller
        self.saverInstaller = saverInstaller
        self.menuBarIcon = menuBarIcon
        self.relauncher = relauncher
        self.updater = updater
    }

    // MARK: - Derived state

    var isBusy: Bool { busyAction != nil }

    /// True while an assertion or `SleepDisabled` keeps the Mac awake.
    var isKeepingAwake: Bool {
        !controller.activeAssertions.isEmpty || status?.sleepDisabled == true
    }

    var displayedError: DisplayedError? {
        actionError ?? controller.lastError.map { DisplayedError($0) }
    }

    var screenSaverSettingsPane: ScreenSaverSettingsPane { saverInstaller.pane }

    func lockBlockingReason(_ mode: LockMode) -> String? {
        LockGate.blockingReason(LockGate.Input(status: status, mode: mode, busy: isBusy))
    }

    // MARK: - Lifecycle

    func launch() {
        guard !launched else { return }
        launched = true
        // A menu bar agent has no windows most of the time; macOS must not reclaim it while it holds assertions.
        ProcessInfo.processInfo.disableAutomaticTermination("ScreenISO menu bar agent")
        Task {
            await refreshStatus()
        }
        Task {
            // The status item is created after launch and its window takes a moment to report whether it is drawn.
            try await Task.sleep(for: .seconds(2))
            refreshMenuBarIcon()
        }
        Task {
            await watchForUpdates()
        }
    }

    func refreshMenuBarIcon() {
        menuBarIconHidden = menuBarIcon.isHidden
    }

    func refreshStatus() async {
        refreshMenuBarIcon()
        guard !isLoadingStatus else { return }
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        do {
            let current = try await statusReader.read()
            status = current
            saverNeedsUpdate = try current.screenSaverInstalled && !saverInstaller.isInstalledCopyCurrent()
            statusError = nil
        } catch {
            let failure = DisplayedError(error)
            AppLog.app.error("status_read_failed code=\(failure.code, privacy: .public)")
            statusError = failure
        }
    }

    // MARK: - Activities

    func isAssertionActive(_ kind: PowerAssertionKind) -> Bool {
        controller.activeAssertions.contains(kind)
    }

    var areAllAssertionsActive: Bool {
        controller.activeAssertions.count == PowerAssertionKind.allCases.count
    }

    func setAllAssertions(active: Bool) {
        actionError = nil
        do {
            try controller.setAllAssertions(active: active)
        } catch {
            AppLog.app.error("assertions_change_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
    }

    func setAssertion(_ kind: PowerAssertionKind, active: Bool) {
        actionError = nil
        do {
            try controller.setAssertion(kind, active: active)
        } catch {
            // The controller keeps the error in `lastError`, which the panel shows.
            AppLog.app.error("assertion_change_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
    }

    func setSleepDisabled(_ disabled: Bool) async {
        actionError = nil
        pendingSleepDisabled = disabled
        busyAction = disabled ? "Disattivazione dello stop" : "Riattivazione dello stop"
        defer {
            busyAction = nil
            pendingSleepDisabled = nil
        }
        do {
            try await controller.setSleepDisabled(disabled)
        } catch {
            AppLog.app.error("sleep_disabled_change_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
        await refreshStatus()
    }

    // MARK: - Lock

    func lock(_ mode: LockMode) async {
        guard lockBlockingReason(mode) == nil else { return }
        actionError = nil
        busyAction = "Blocco dello schermo"
        defer { busyAction = nil }
        do {
            try await controller.lock(mode)
        } catch {
            AppLog.app.error("lock_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
        await refreshStatus()
    }

    // MARK: - Setup actions

    func installSudoRule() async {
        await perform("Installazione della regola") {
            try await self.sudoersInstaller.install(forUser: NSUserName())
        }
    }

    func removeSudoRule() async {
        await perform("Rimozione della regola") {
            try await self.sudoersInstaller.remove()
        }
    }

    func installScreenSaver() async {
        await perform("Installazione del salvaschermo") {
            try await self.saverInstaller.install()
            try self.saverInstaller.openSettings()
        }
    }

    func updateScreenSaver() async {
        await perform("Aggiornamento del salvaschermo") {
            try await self.saverInstaller.install()
        }
    }

    func openScreenSaverSettings() {
        actionError = nil
        do {
            try saverInstaller.openSettings()
        } catch {
            actionError = DisplayedError(error)
        }
    }

    /// Brings the icon back into view. AppKit reads the position when it creates the icon, and removing and
    /// inserting a `MenuBarExtra` again blocks the main thread on macOS 26.6: the app starts a new copy and quits.
    func showMenuBarIcon() async {
        actionError = nil
        menuBarIcon.savePositionNextToSystemIcons()
        await relaunch()
    }

    // MARK: - Updates

    private func watchForUpdates() async {
        guard updater.isManagedByHomebrew else {
            AppLog.app.info("update_check_skipped reason=not_installed_by_homebrew")
            return
        }
        while !Task.isCancelled {
            await checkForUpdate()
            do {
                try await Task.sleep(for: Self.updateCheckInterval)
            } catch {
                return
            }
        }
    }

    func checkForUpdate() async {
        do {
            availableUpdate = try await updater.availableUpdate()
            AppLog.app.info("update_checked available=\(self.availableUpdate?.description ?? "none", privacy: .public)")
        } catch {
            // Nobody asked for this check and the panel has nothing to offer about it: the failure goes to the log.
            AppLog.app.error("update_check_failed code=\(DisplayedError(error).code, privacy: .public)")
        }
    }

    /// Installs on request only. The assertions stay active while `brew` works and are released at the restart.
    func installUpdate() async {
        guard let version = availableUpdate else { return }
        actionError = nil
        busyAction = "Aggiornamento alla \(version)"
        do {
            try await updater.install()
        } catch {
            busyAction = nil
            let failure = DisplayedError(error)
            AppLog.app.error("update_install_failed code=\(failure.code, privacy: .public)")
            actionError = failure
            return
        }
        AppLog.app.info("update_installed version=\(version.description, privacy: .public)")
        availableUpdate = nil
        await relaunch()
    }

    /// Releases the assertions first, as `quit()` does, then starts a new copy of the app and quits this one.
    private func relaunch() async {
        do {
            try controller.setAllAssertions(active: false)
        } catch {
            busyAction = nil
            AppLog.app.error("relaunch_release_failed code=\(ScreenISOError(error).code, privacy: .public)")
            return
        }
        busyAction = "Riavvio di ScreenISO"
        do {
            try await relauncher.launchNewInstance()
        } catch {
            busyAction = nil
            let failure = DisplayedError(error)
            AppLog.app.error("relaunch_failed code=\(failure.code, privacy: .public)")
            actionError = failure
            return
        }
        AppLog.app.info("app_relaunched")
        NSApplication.shared.terminate(nil)
    }

    func openLockScreenSettings() {
        actionError = nil
        do {
            try SystemSettings.open(LockScreenSettingsPane.url)
        } catch {
            actionError = DisplayedError(error)
        }
    }

    func openAuditLog() {
        let url = FileAuditLog.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            actionError = DisplayedError(AppError.auditLogMissing(path: url.path))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Releases the assertions first, so the audit log records that they ended with the app. A failure is shown
    /// and the app stays open; the assertions are no longer tracked after it, so a second attempt quits.
    func quit() {
        actionError = nil
        do {
            try controller.setAllAssertions(active: false)
        } catch {
            AppLog.app.error("quit_release_failed code=\(ScreenISOError(error).code, privacy: .public)")
            return
        }
        AppLog.app.info("app_quit")
        NSApplication.shared.terminate(nil)
    }

    private func perform(_ label: String, _ action: @MainActor () async throws -> Void) async {
        actionError = nil
        busyAction = label
        defer { busyAction = nil }
        do {
            try await action()
        } catch {
            let failure = DisplayedError(error)
            AppLog.app.error("action_failed action=\(label, privacy: .public) code=\(failure.code, privacy: .public)")
            actionError = failure
        }
        await refreshStatus()
    }
}
