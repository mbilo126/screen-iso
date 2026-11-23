import Foundation
import ScreenISOCore

enum Labels {
    static let allAssertionsTitle = "tutte"
    static let allAssertionsHelp = "Attiva o disattiva tutte le opzioni di caffeinate"
    static let sleepDisabledHelp = "Il Mac non va in stop nemmeno a coperchio chiuso (pmset disablesleep)"
    static let showMenuBarIconTitle = "Mostra icona nella barra dei menu"
    static let menuBarIconHiddenNotice =
        "L'icona di ScreenISO non è visibile nella barra dei menu: la barra è piena. Il pulsante riavvia ScreenISO e mette l'icona accanto a quelle di sistema. Le opzioni di caffeinate attive vengono spente."

    static func updateButtonTitle(_ version: AppVersion) -> String {
        "Aggiorna alla \(version)"
    }

    static func updateNotice(_ version: AppVersion) -> String {
        "È disponibile ScreenISO \(version). L'aggiornamento passa da Homebrew e riavvia ScreenISO: le opzioni di caffeinate attive vengono spente."
    }

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
