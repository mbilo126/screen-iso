import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@Suite("Start gate")
struct StartGateTests {
    static func status(
        policy: ScreenLockPolicy = .immediate,
        sudoRuleInstalled: Bool = false,
        lockSymbolResolvable: Bool = true,
        screenSaverInstalled: Bool = false
    ) -> SystemStatus {
        SystemStatus(
            screenLockPolicy: policy,
            screenLockPolicyRaw: "screenLock delay is immediate",
            sleepDisabled: false,
            sudoRuleInstalled: sudoRuleInstalled,
            lockSymbolResolvable: lockSymbolResolvable,
            touchIDAvailable: false,
            screenSaverInstalled: screenSaverInstalled,
            screenSaverSelected: false
        )
    }

    static func input(
        status: SystemStatus? = StartGateTests.status(),
        configuration: SessionConfiguration = .default,
        recoveryPending: Bool = false,
        corruptedSnapshot: Bool = false,
        busy: Bool = false
    ) -> StartGate.Input {
        StartGate.Input(
            status: status,
            configuration: configuration,
            recoveryPending: recoveryPending,
            corruptedSnapshot: corruptedSnapshot,
            busy: busy
        )
    }

    @Test("ready with an immediate lock, the lock symbol and the default configuration")
    func ready() {
        #expect(StartGate.blockingReason(Self.input()) == nil)
    }

    @Test("Touch ID is informative and never blocks")
    func touchIDInformative() {
        var status = Self.status()
        status.touchIDAvailable = false
        #expect(StartGate.blockingReason(Self.input(status: status)) == nil)
    }

    @Test(
        "each missing requirement blocks with its reason",
        arguments: [
            (input(status: nil), "Stato del sistema non disponibile"),
            (input(status: status(policy: .delay(seconds: 5))), "macOS non chiede la password subito dopo il blocco"),
            (input(status: status(policy: .off)), "macOS non chiede la password subito dopo il blocco"),
            (input(status: status(lockSymbolResolvable: false)), "La funzione di blocco di macOS non è disponibile"),
            (
                input(configuration: SessionConfiguration(keepAwakeWithLidClosed: true)),
                "Per restare sveglio a coperchio chiuso serve la regola sudoers"
            ),
            (
                input(configuration: SessionConfiguration(lockMode: .screenSaver)),
                "Il salvaschermo ScreenISO non è installato"
            ),
            (
                input(configuration: SessionConfiguration(powerAssertions: [])),
                "Attiva almeno un'opzione di alimentazione"
            ),
            (input(recoveryPending: true), "Controllo di una sessione precedente in corso"),
            (input(corruptedSnapshot: true), "Scarta prima lo stato salvato non leggibile"),
            (input(busy: true), "Operazione in corso"),
        ]
    )
    func blocked(_ input: StartGate.Input, _ reason: String) {
        #expect(StartGate.blockingReason(input) == reason)
    }

    @Test("the lid option is allowed once the sudoers rule is active")
    func lidWithRule() {
        let input = Self.input(
            status: Self.status(sudoRuleInstalled: true),
            configuration: SessionConfiguration(powerAssertions: [], keepAwakeWithLidClosed: true)
        )
        #expect(StartGate.blockingReason(input) == nil)
    }

    @Test("screen saver mode is allowed once the saver is installed")
    func screenSaverInstalled() {
        let input = Self.input(
            status: Self.status(screenSaverInstalled: true),
            configuration: SessionConfiguration(lockMode: .screenSaver)
        )
        #expect(StartGate.blockingReason(input) == nil)
    }
}
