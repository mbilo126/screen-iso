import Foundation
import ScreenISOCore

/// Decides whether "Avvia sessione protetta" is enabled and, when it is not, why.
enum StartGate {
    struct Input: Equatable {
        var status: SystemStatus?
        var configuration: SessionConfiguration
        var recoveryPending: Bool
        var corruptedSnapshot: Bool
        var busy: Bool
    }

    /// The first missing requirement, or nil when a session can start.
    static func blockingReason(_ input: Input) -> String? {
        if input.corruptedSnapshot {
            return "Scarta prima lo stato salvato non leggibile"
        }
        if input.recoveryPending {
            return "Controllo di una sessione precedente in corso"
        }
        if input.busy {
            return "Operazione in corso"
        }
        guard let status = input.status else {
            return "Stato del sistema non disponibile"
        }
        if !status.screenLockCompliant {
            return "macOS non chiede la password subito dopo il blocco"
        }
        if !status.lockSymbolResolvable {
            return "La funzione di blocco di macOS non è disponibile"
        }
        let configuration = input.configuration
        if configuration.powerAssertions.isEmpty && !configuration.keepAwakeWithLidClosed {
            return "Attiva almeno un'opzione di alimentazione"
        }
        if configuration.keepAwakeWithLidClosed && !status.sudoRuleInstalled {
            return "Per restare sveglio a coperchio chiuso serve la regola sudoers"
        }
        if configuration.lockMode == .screenSaver && !status.screenSaverInstalled {
            return "Il salvaschermo ScreenISO non è installato"
        }
        return nil
    }
}
