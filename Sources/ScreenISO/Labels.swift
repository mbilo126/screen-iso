import Foundation
import ScreenISOCore

enum Labels {
    static let screenLockFixCommand = "sysadminctl -screenLock immediate -password -"
    static let restoreSleepCommand = "sudo pmset -a disablesleep 0"

    static func title(of kind: PowerAssertionKind) -> String {
        let label =
            switch kind {
            case .preventIdleSystemSleep: "Impedisci lo stop per inattività"
            case .preventSystemSleep: "Impedisci lo stop con alimentatore collegato"
            case .preventDisplaySleep: "Impedisci lo spegnimento dello schermo"
            case .preventDiskIdle: "Impedisci lo stop dei dischi"
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

    /// "HH:mm" in the user's time zone; the stored timestamp stays UTC.
    static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: date)
    }
}
