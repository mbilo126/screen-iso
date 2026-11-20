import Foundation
import Testing

@testable import ScreenISOCore

@Suite("pmset disablesleep")
struct LidSleepTests {
    static let pmsetSample = """
        System-wide power settings:
         SleepDisabled\t\t0
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         disksleep            10
         sleep                1 (sleep prevented by coreaudiod)
         displaysleep         10
        """

    @Test("SleepDisabled 0 from a real pmset -g output")
    func parsesZero() throws {
        #expect(try PmsetOutputParser.sleepDisabled(from: Self.pmsetSample) == false)
    }

    @Test("SleepDisabled 1")
    func parsesOne() throws {
        let output = Self.pmsetSample.replacingOccurrences(of: "SleepDisabled\t\t0", with: "SleepDisabled\t\t1")
        #expect(try PmsetOutputParser.sleepDisabled(from: output) == true)
    }

    @Test("a missing SleepDisabled line means 0")
    func missingLine() throws {
        let output = "Currently in use:\n standby 1\n sleep 1\n"
        #expect(try PmsetOutputParser.sleepDisabled(from: output) == false)
        #expect(try PmsetOutputParser.sleepDisabled(from: "") == false)
    }

    @Test(
        "unexpected values fail loud", arguments: [" SleepDisabled\t\t2", " SleepDisabled", " SleepDisabled 1 extra"])
    func unexpectedValue(line: String) {
        #expect(throws: ScreenISOError.pmsetOutputUnparseable(line: line)) {
            try PmsetOutputParser.sleepDisabled(from: "System-wide power settings:\n\(line)\n")
        }
    }

    @Test("reads through pmset -g")
    @MainActor
    func readsThroughRunner() async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 0, stdout: Self.pmsetSample, stderr: ""))
        let controller = PmsetLidSleepController(runner: runner)

        #expect(try await controller.isSleepDisabled() == false)
        #expect(await runner.commands == [RecordedCommand(executable: "/usr/bin/pmset", arguments: ["-g"])])
    }

    @Test("writes through sudo -n pmset -a disablesleep", arguments: [true, false])
    @MainActor
    func writesThroughSudo(value: Bool) async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 0, stdout: "", stderr: ""))
        let controller = PmsetLidSleepController(runner: runner)

        try await controller.setSleepDisabled(value)

        let expected = RecordedCommand(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"]
        )
        #expect(await runner.commands == [expected])
    }

    @Test("a refused sudo write fails loud")
    @MainActor
    func writeFailure() async throws {
        let runner = RecordingCommandRunner(
            output: CommandOutput(exitCode: 1, stdout: "", stderr: "sudo: a password is required\n")
        )
        let controller = PmsetLidSleepController(runner: runner)

        await #expect(throws: ScreenISOError.self) {
            try await controller.setSleepDisabled(true)
        }
    }

    @Test("the sudo rule is active only when both variants are allowed")
    @MainActor
    func sudoRuleCheck() async throws {
        let allowed = RecordingCommandRunner(output: CommandOutput(exitCode: 0, stdout: "", stderr: ""))
        #expect(try await PmsetLidSleepController(runner: allowed).isSudoRuleActive())
        #expect(
            await allowed.commands == [
                RecordedCommand(
                    executable: "/usr/bin/sudo",
                    arguments: ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]
                ),
                RecordedCommand(
                    executable: "/usr/bin/sudo",
                    arguments: ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]
                ),
            ]
        )

        let denied = RecordingCommandRunner(output: CommandOutput(exitCode: 1, stdout: "", stderr: ""))
        #expect(try await PmsetLidSleepController(runner: denied).isSudoRuleActive() == false)

        let onlyEnable = RecordingCommandRunner { command in
            CommandOutput(exitCode: command.arguments.last == "1" ? 0 : 1, stdout: "", stderr: "")
        }
        #expect(try await PmsetLidSleepController(runner: onlyEnable).isSudoRuleActive() == false)
    }
}

@Suite("Power assertion kinds")
struct PowerAssertionKindTests {
    @Test("IOKit types and caffeinate flags")
    func mapping() {
        let mapping = PowerAssertionKind.allCases.map { ($0.assertionType, $0.caffeinateFlag) }
        #expect(
            mapping.map(\.0) == [
                "PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventDiskIdle",
                "UserIsActive",
            ])
        #expect(mapping.map(\.1) == ["-d", "-i", "-s", "-m", "-u"])
    }
}
