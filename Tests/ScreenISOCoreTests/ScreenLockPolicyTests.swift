import Foundation
import Testing

@testable import ScreenISOCore

@Suite("sysadminctl -screenLock status parser")
struct ScreenLockPolicyTests {
    @Test(
        "recognised messages",
        arguments: [
            (
                "2026-11-17 15:34:08.831 sysadminctl[12056:541951] screenLock delay is 300 seconds",
                ScreenLockPolicy.delay(seconds: 300), "screenLock delay is 300 seconds"
            ),
            (
                "2026-11-17 15:34:08.831 sysadminctl[12056:541951] screenLock delay is immediate",
                .immediate, "screenLock delay is immediate"
            ),
            ("2026-11-17 15:34:08.831 sysadminctl[1:2] screenLock is off", .off, "screenLock is off"),
            ("screenLock delay is immediate", .immediate, "screenLock delay is immediate"),
            ("screenLock delay is 0 seconds", .immediate, "screenLock delay is 0 seconds"),
            ("screenLock delay is 1 second", .delay(seconds: 1), "screenLock delay is 1 second"),
            ("SCREENLOCK IS OFF\n", .off, "SCREENLOCK IS OFF"),
            ("\nscreenLock delay is 5 seconds\n\n", .delay(seconds: 5), "screenLock delay is 5 seconds"),
        ]
    )
    func recognised(output: String, expected: ScreenLockPolicy, raw: String) {
        let status = ScreenLockStatusParser.parse(output)
        #expect(status.policy == expected)
        #expect(status.raw == raw)
    }

    @Test(
        "unrecognised output keeps the raw string",
        arguments: [
            (
                "2026-11-17 15:34:08.831 sysadminctl[1:2] Unknown state for screenLock (weird)",
                "Unknown state for screenLock (weird)"
            ),
            ("screenLock delay is soon", "screenLock delay is soon"),
            ("Operation not permitted", "Operation not permitted"),
            ("", ""),
        ]
    )
    func unrecognised(output: String, raw: String) {
        let status = ScreenLockStatusParser.parse(output)
        #expect(status.policy == .unrecognized(raw: raw))
        #expect(status.raw == raw)
    }

    @Test("only an immediate lock is compliant")
    func compliance() {
        #expect(ScreenLockPolicy.immediate.isCompliant)
        #expect(!ScreenLockPolicy.delay(seconds: 5).isCompliant)
        #expect(!ScreenLockPolicy.off.isCompliant)
        #expect(!ScreenLockPolicy.unrecognized(raw: "x").isCompliant)
    }

    @Test(
        "policy JSON shape",
        arguments: [
            (ScreenLockPolicy.immediate, #"{"kind":"immediate"}"#),
            (.delay(seconds: 300), #"{"kind":"delay","seconds":300}"#),
            (.off, #"{"kind":"off"}"#),
            (.unrecognized(raw: "x"), #"{"kind":"unrecognized","raw":"x"}"#),
        ]
    )
    func json(policy: ScreenLockPolicy, json: String) throws {
        let data = try JSONCoding.encoder().encode(policy)
        #expect(String(decoding: data, as: UTF8.self) == json)
        #expect(try JSONCoding.decoder().decode(ScreenLockPolicy.self, from: data) == policy)
    }

    @Test("the provider runs sysadminctl and parses stderr")
    @MainActor
    func provider() async throws {
        let runner = RecordingCommandRunner(
            output: CommandOutput(
                exitCode: 0,
                stdout: "",
                stderr: "2026-11-17 15:34:08.831 sysadminctl[12056:541951] screenLock delay is immediate\n"
            )
        )
        let provider = SysadminctlScreenLockPolicyProvider(runner: runner)

        let status = try await provider.currentPolicy()

        #expect(status.policy == .immediate)
        #expect(
            await runner.commands == [
                RecordedCommand(executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"])
            ]
        )
    }

    @Test("the provider fails loud on a non zero exit")
    @MainActor
    func providerFailure() async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 1, stdout: "", stderr: "boom"))
        let provider = SysadminctlScreenLockPolicyProvider(runner: runner)

        await #expect(
            throws: ScreenISOError.commandFailed(executable: "/usr/sbin/sysadminctl", exitCode: 1, stderr: "boom")
        ) {
            try await provider.currentPolicy()
        }
    }
}
