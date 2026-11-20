import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@Suite("Error messages")
struct ErrorMessagesTests {
    static let coreErrors: [ScreenISOError] = [
        .commandLaunchFailed(executable: "/usr/bin/pmset", message: "not found"),
        .commandFailed(executable: "/usr/bin/sudo", exitCode: 1, stderr: "denied"),
        .pmsetOutputUnparseable(line: "SleepDisabled x"),
        .invalidUsername("ROOT"),
        .authorizationCancelled,
        .sudoersInstallFailed(stderr: "syntax error"),
        .sudoersRemovalFailed(stderr: "busy"),
        .lockSymbolUnavailable(detail: "symbol not found"),
        .screenSaverLaunchFailed(message: "no app"),
        .sessionInfoUnavailable,
        .powerAssertionCreateFailed(kind: .preventSystemSleep, ioReturn: -1),
        .powerAssertionReleaseFailed(kind: .preventDiskIdle, ioReturn: -1),
        .screenLockNotImmediate(.delay(seconds: 5)),
        .sudoRuleMissing,
        .lockNotConfirmed(lockMode: .screenSaver),
        .lockAlreadyInProgress,
        .fileWriteFailed(path: "/tmp/a", message: "denied"),
        .fileReadFailed(path: "/tmp/b", message: "missing"),
        .multipleFailures([.sudoRuleMissing, .lockAlreadyInProgress]),
        .unexpected(message: "boom"),
    ]

    static let appErrors: [AppError] = [
        .saverResourceMissing,
        .saverInstallFailed(message: "exists"),
        .saverHostReloadFailed(message: "pkill: failed"),
        .settingsOpenFailed(url: ScreenSaverSettingsPane.wallpaper.url),
        .auditLogMissing(path: "/tmp/audit.jsonl"),
    ]

    @Test("every Core error code has an Italian message", arguments: coreErrors)
    func coreErrorMapped(_ error: ScreenISOError) {
        #expect(ErrorMessages.byCode[error.code] != nil, "unmapped code \(error.code)")
        let message = ErrorMessages.message(for: error)
        #expect(!message.isEmpty)
        #expect(message != error.code)
    }

    @Test("every app error code has an Italian message", arguments: appErrors)
    func appErrorMapped(_ error: AppError) {
        #expect(ErrorMessages.byCode[error.code] != nil, "unmapped code \(error.code)")
        #expect(ErrorMessages.message(for: error) != error.code)
    }

    @Test("an unmapped code is shown as the code itself")
    func unmappedCode() {
        #expect(ErrorMessages.message(forCode: "brand_new_failure", detail: "ignored") == "brand_new_failure")
    }

    @Test("detail is appended after the Italian message")
    func detailAppended() {
        #expect(
            ErrorMessages.message(for: .screenLockNotImmediate(.delay(seconds: 5)))
                == "macOS non chiede la password subito dopo il blocco: impostazione attuale dopo 5 secondi"
        )
        #expect(
            ErrorMessages.message(for: .authorizationCancelled) == "Autorizzazione di amministratore annullata"
        )
    }

    @Test("multiple_failures lists the nested failures")
    func nestedFailures() {
        let message = ErrorMessages.message(for: .multipleFailures([.sudoRuleMissing, .lockAlreadyInProgress]))
        #expect(message.hasPrefix("Più operazioni non riuscite: "))
        #expect(message.contains("La regola sudoers per pmset disablesleep non è attiva"))
        #expect(message.contains("Un blocco dello schermo è già in corso"))
    }

    @Test("DisplayedError keeps the code and wraps foreign errors")
    func displayedError() {
        struct Foreign: Error {}
        #expect(DisplayedError(ScreenISOError.sudoRuleMissing).code == "sudo_rule_missing")
        #expect(DisplayedError(AppError.saverResourceMissing as any Error).code == "saver_resource_missing")
        #expect(DisplayedError(Foreign()).code == "unexpected_error")
    }

    @Test("no message contains an em dash")
    func noEmDash() {
        for message in ErrorMessages.byCode.values {
            #expect(!message.contains("\u{2014}"), "em dash in \(message)")
        }
    }
}
