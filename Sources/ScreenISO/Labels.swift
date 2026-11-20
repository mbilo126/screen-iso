import Foundation
import ScreenISOCore

enum Labels {
    static let screenLockFixCommand = "sysadminctl -screenLock immediate -password -"
    static let restoreSleepCommand = "sudo pmset -a disablesleep 0"
    static let allAssertionsTitle = "tutte"
    static let allAssertionsHelp = "Attiva o disattiva tutte le opzioni di caffeinate"
    static let sleepDisabledHelp = "Il Mac non va in stop nemmeno a coperchio chiuso (pmset disablesleep)"

    static func title(of kind: PowerAssertionKind) -> String {
        let label =
            switch kind {
            case .preventDisplaySleep: "Impedisci lo spegnimento dello schermo"
            case .preventIdleSystemSleep: "Impedisci lo stop per inattività"
            case .preventSystemSleep: "Impedisci lo stop con alimentatore collegato"
            case .preventDiskIdle: "Impedisci lo stop dei dischi"
            case .userIsActive: "Dichiara l'utente attivo e tieni acceso lo schermo"
            }
        return "\(label) (caffeinate \(kind.caffeinateFlag))"
    }

    static func title(of mode: LockMode) -> String {
        switch mode {
        case .loginWindow: "Schermata di blocco"
        case .screenSaver: "Salvaschermo"
        }
    }

    static func description(of policy: ScreenLockPolicy) -> String {
        switch policy {
        case .immediate: "subito"
        case .delay(let seconds): seconds == 1 ? "dopo 1 secondo" : "dopo \(seconds) secondi"
        case .off: "password non richiesta"
        case .unrecognized(let raw): "non riconosciuta (\(raw))"
        }
    }
}
