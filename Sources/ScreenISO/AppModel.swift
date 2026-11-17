import AppKit
import Foundation
import Observation
import ScreenISOCore

@MainActor
@Observable
final class AppModel {
    let controller: SessionController

    private(set) var configuration: SessionConfiguration
    private(set) var status: SystemStatus?
    private(set) var statusError: DisplayedError?
    private(set) var isLoadingStatus = false

    private(set) var recoveryPending = true
    private(set) var recoveryError: DisplayedError?
    private(set) var corruptedSnapshot: DisplayedError?
    private(set) var recoveredNotice: String?

    private(set) var actionError: DisplayedError?
    private(set) var busyAction: String?
    private(set) var saverJustInstalled = false
    private(set) var saverNeedsUpdate = false

    @ObservationIgnored private let statusReader: SystemStatusReader
    @ObservationIgnored private let sudoersInstaller: any SudoersRuleInstalling
    @ObservationIgnored private let configurationStore: ConfigurationStore
    @ObservationIgnored private let saverInstaller: ScreenSaverInstaller
    @ObservationIgnored private var launched = false

    init(
        controller: SessionController = .live(),
        statusReader: SystemStatusReader = .live(),
        sudoersInstaller: any SudoersRuleInstalling = AppleScriptSudoersInstaller(),
        configurationStore: ConfigurationStore = ConfigurationStore(),
        saverInstaller: ScreenSaverInstaller = ScreenSaverInstaller()
    ) {
        self.controller = controller
        self.statusReader = statusReader
        self.sudoersInstaller = sudoersInstaller
        self.configurationStore = configurationStore
        self.saverInstaller = saverInstaller
        do {
            configuration = try configurationStore.load()
        } catch {
            configuration = .default
            actionError = DisplayedError(error)
        }
    }

    // MARK: - Derived state

    var isSessionRunning: Bool { controller.phase != .idle }

    var isBusy: Bool { busyAction != nil }

    var screenSaverSettingsPane: ScreenSaverSettingsPane { saverInstaller.pane }

    var sessionError: DisplayedError? {
        guard let error = controller.lastError else { return nil }
        if corruptedSnapshot != nil, error.code == "snapshot_corrupted" {
            return nil
        }
        return DisplayedError(error)
    }

    var startBlockingReason: String? {
        StartGate.blockingReason(
            StartGate.Input(
                status: status,
                configuration: configuration,
                recoveryPending: recoveryPending,
                corruptedSnapshot: corruptedSnapshot != nil,
                busy: isBusy
            )
        )
    }

    // MARK: - Lifecycle

    func launch() {
        guard !launched else { return }
        launched = true
        // A menu bar agent has no windows most of the time; macOS must not reclaim it while it holds a session.
        ProcessInfo.processInfo.disableAutomaticTermination("ScreenISO menu bar agent")
        Task {
            await recover()
            await refreshStatus()
        }
    }

    func recover() async {
        recoveryPending = true
        recoveryError = nil
        defer { recoveryPending = false }
        do {
            if let snapshot = try await controller.recoverIfNeeded() {
                recoveredNotice =
                    "Ripristinata una sessione interrotta iniziata il \(Labels.dateTime(snapshot.startedAt))"
                AppLog.app.notice("orphaned_session_recovered")
            }
        } catch {
            let failure = ScreenISOError(error)
            AppLog.app.error("recovery_failed code=\(failure.code, privacy: .public)")
            if case .snapshotCorrupted = failure {
                corruptedSnapshot = DisplayedError(failure)
            } else {
                recoveryError = DisplayedError(failure)
            }
        }
    }

    func discardSnapshot() async {
        actionError = nil
        do {
            try controller.discardSnapshot()
            corruptedSnapshot = nil
        } catch {
            actionError = DisplayedError(error)
        }
        await refreshStatus()
    }

    func refreshStatus() async {
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

    // MARK: - Configuration

    func isPowerAssertionEnabled(_ kind: PowerAssertionKind) -> Bool {
        configuration.powerAssertions.contains(kind)
    }

    func setPowerAssertion(_ kind: PowerAssertionKind, enabled: Bool) {
        var updated = configuration
        if enabled {
            updated.powerAssertions.insert(kind)
        } else {
            updated.powerAssertions.remove(kind)
        }
        apply(updated)
    }

    func setKeepAwakeWithLidClosed(_ enabled: Bool) {
        var updated = configuration
        updated.keepAwakeWithLidClosed = enabled
        apply(updated)
    }

    func setLockMode(_ mode: LockMode) {
        var updated = configuration
        updated.lockMode = mode
        apply(updated)
    }

    private func apply(_ updated: SessionConfiguration) {
        configuration = updated
        do {
            try configurationStore.save(updated)
            if actionError?.code == "configuration_unreadable" || actionError?.code == "configuration_write_failed" {
                actionError = nil
            }
        } catch {
            actionError = DisplayedError(error)
        }
    }

    // MARK: - Actions

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
            self.saverJustInstalled = true
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

    func startSession() async {
        guard startBlockingReason == nil else { return }
        actionError = nil
        recoveredNotice = nil
        busyAction = "Avvio della sessione"
        defer { busyAction = nil }
        do {
            try await controller.start(configuration)
        } catch {
            AppLog.app.error("session_start_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
        await refreshStatus()
    }

    @discardableResult
    func endSession() async -> Bool {
        busyAction = "Chiusura della sessione"
        defer { busyAction = nil }
        var ended = true
        do {
            try await controller.end()
        } catch {
            ended = false
            AppLog.app.error("session_end_failed code=\(ScreenISOError(error).code, privacy: .public)")
        }
        await refreshStatus()
        return ended
    }

    func openAuditLog() {
        let url = FileAuditLog.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            actionError = DisplayedError(AppError.auditLogMissing(path: url.path))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Ends a running session first, so `disablesleep` is restored instead of being left to the next launch.
    func quit() async {
        if case .active = controller.phase {
            guard await endSession() else { return }
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
