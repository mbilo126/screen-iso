import Foundation
import ScreenISOCore

/// Italian messages keyed by error code. An unmapped code is shown as is, so a message is never empty.
enum ErrorMessages {
    static let byCode: [String: String] = [
        "command_launch_failed": "Impossibile avviare un comando di sistema",
        "command_failed": "Un comando di sistema è terminato con un errore",
        "pmset_output_unparseable": "La risposta di pmset non è stata riconosciuta",
        "invalid_username": "Il nome utente non è valido per la regola sudoers",
        "authorization_cancelled": "Autorizzazione di amministratore annullata",
        "sudoers_install_failed": "Installazione della regola sudoers non riuscita",
        "sudoers_removal_failed": "Rimozione della regola sudoers non riuscita",
        "lock_symbol_unavailable": "La funzione di blocco di macOS non è disponibile",
        "screen_saver_launch_failed": "Impossibile avviare il salvaschermo",
        "session_info_unavailable": "Impossibile leggere lo stato della sessione grafica",
        "power_assertion_create_failed": "Impossibile impedire lo stop",
        "power_assertion_release_failed": "Impossibile ripristinare lo stop",
        "screen_lock_not_immediate": "macOS non chiede la password subito dopo il blocco",
        "sudo_rule_missing": "La regola sudoers per pmset disablesleep non è attiva",
        "lock_not_confirmed": "Il blocco dello schermo non è stato confermato",
        "lock_already_in_progress": "Un blocco dello schermo è già in corso",
        "file_write_failed": "Impossibile scrivere un file",
        "file_read_failed": "Impossibile leggere un file",
        "multiple_failures": "Più operazioni non riuscite",
        "unexpected_error": "Errore imprevisto",
        "saver_resource_missing": "Il salvaschermo non è incluso nell'app, ricostruisci il bundle con make build",
        "saver_install_failed": "Installazione del salvaschermo non riuscita",
        "saver_host_reload_failed":
            "Salvaschermo aggiornato, ma macOS userà la versione nuova solo dopo il prossimo riavvio della sessione",
        "settings_open_failed": "Impossibile aprire le Impostazioni di Sistema",
        "audit_log_missing": "Il registro non esiste ancora, verrà creato al primo evento",
        "relaunch_failed": "Riavvio di ScreenISO non riuscito",
    ]

    static func message(forCode code: String, detail: String = "") -> String {
        guard let base = byCode[code] else { return code }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : "\(base): \(trimmed)"
    }

    static func message(for error: ScreenISOError) -> String {
        message(forCode: error.code, detail: detail(for: error))
    }

    static func message(for error: AppError) -> String {
        message(forCode: error.code, detail: error.detail)
    }

    private static func detail(for error: ScreenISOError) -> String {
        switch error {
        case .commandLaunchFailed(let executable, let message):
            "\(executable), \(message)"
        case .commandFailed(let executable, let exitCode, let stderr):
            "\(executable) ha restituito \(exitCode). \(stderr)"
        case .pmsetOutputUnparseable(let line):
            line
        case .invalidUsername(let name):
            name
        case .authorizationCancelled, .sessionInfoUnavailable, .sudoRuleMissing, .lockAlreadyInProgress:
            ""
        case .sudoersInstallFailed(let stderr), .sudoersRemovalFailed(let stderr):
            stderr
        case .lockSymbolUnavailable(let detail):
            "SACLockScreenImmediate, \(detail)"
        case .screenSaverLaunchFailed(let message):
            message
        case .powerAssertionCreateFailed(let kind, let ioReturn), .powerAssertionReleaseFailed(let kind, let ioReturn):
            "\(kind.caffeinateFlag) (\(kind.assertionType)), IOReturn \(ioReturn)"
        case .screenLockNotImmediate(let policy):
            "impostazione attuale \(Labels.description(of: policy))"
        case .lockNotConfirmed(let lockMode):
            "modalità \(Labels.title(of: lockMode))"
        case .fileWriteFailed(let path, let message), .fileReadFailed(let path, let message):
            "\(path). \(message)"
        case .multipleFailures(let errors):
            errors.map { message(for: $0) }.joined(separator: "; ")
        case .unexpected(let message):
            message
        }
    }
}
