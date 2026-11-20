import Foundation
import ScreenISOCore

/// Decides whether a lock button is enabled and, when it is not, why.
enum LockGate {
    struct Input: Equatable {
        var status: SystemStatus?
        var mode: LockMode
        var busy: Bool
    }

    /// The first missing requirement, or nil when the screen can be locked in this mode.
    static func blockingReason(_ input: Input) -> String? {
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
        if input.mode == .screenSaver && !status.screenSaverInstalled {
            return "Il salvaschermo ScreenISO non è installato"
        }
        return nil
    }
}
