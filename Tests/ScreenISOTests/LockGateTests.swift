import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@Suite("Lock gate")
struct LockGateTests {
    static func status(
        policy: ScreenLockPolicy = .immediate,
        lockSymbolResolvable: Bool = true,
        screenSaverInstalled: Bool = false
    ) -> SystemStatus {
        SystemStatus(
            screenLockPolicy: policy,
            screenLockPolicyRaw: "screenLock delay is immediate",
            sleepDisabled: false,
            sudoRuleInstalled: false,
            lockSymbolResolvable: lockSymbolResolvable,
            touchIDAvailable: false,
            screenSaverInstalled: screenSaverInstalled,
            screenSaverSelected: false
        )
    }

    static func input(
        status: SystemStatus? = LockGateTests.status(),
        mode: LockMode = .loginWindow,
        busy: Bool = false
    ) -> LockGate.Input {
        LockGate.Input(status: status, mode: mode, busy: busy)
    }

    @Test("the lock screen needs only an immediate policy and the lock symbol")
    func lockScreenReady() {
        #expect(LockGate.blockingReason(Self.input()) == nil)
    }

    @Test("no activity, sudoers rule or Touch ID is required to lock")
    func nothingElseRequired() {
        var status = Self.status()
        status.sudoRuleInstalled = false
        status.touchIDAvailable = false
        status.sleepDisabled = false
        #expect(LockGate.blockingReason(Self.input(status: status)) == nil)
    }

    @Test(
        "each missing requirement blocks with its reason",
        arguments: [
            (input(status: nil), "Stato del sistema non disponibile"),
            (input(status: status(policy: .delay(seconds: 5))), "macOS non chiede la password subito dopo il blocco"),
            (input(status: status(policy: .off)), "macOS non chiede la password subito dopo il blocco"),
            (input(status: status(lockSymbolResolvable: false)), "La funzione di blocco di macOS non è disponibile"),
            (input(mode: .screenSaver), "Il salvaschermo ScreenISO non è installato"),
            (input(busy: true), "Operazione in corso"),
        ]
    )
    func blocked(_ input: LockGate.Input, _ reason: String) {
        #expect(LockGate.blockingReason(input) == reason)
    }

    @Test("the screen saver button is enabled once the saver is installed")
    func screenSaverInstalled() {
        let input = Self.input(status: Self.status(screenSaverInstalled: true), mode: .screenSaver)
        #expect(LockGate.blockingReason(input) == nil)
    }

    @Test("a missing saver does not block the lock screen button")
    func lockScreenWithoutSaver() {
        #expect(LockGate.blockingReason(Self.input(status: Self.status(screenSaverInstalled: false))) == nil)
    }
}
