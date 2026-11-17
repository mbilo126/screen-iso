import Foundation
import Testing

@testable import ScreenISOCore

@Suite("Sudoers rule")
struct SudoersRuleTests {
    @Test("rule content")
    func content() throws {
        #expect(
            try SudoersRule.content(forUser: "michelebilotta")
                == "michelebilotta ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        )
    }

    @Test("valid user names", arguments: ["michelebilotta", "_mbsetupuser", "john.doe", "a-b", "x", "u1"])
    func validNames(name: String) throws {
        try SudoersRule.validateUsername(name)
    }

    @Test(
        "invalid user names are rejected",
        arguments: [
            "", "ALL", "Root", "root ALL", "a;b", "a\nb", "a\tb", "-x", ".x", "1abc", "%admin", "#0", "+netgroup",
            "user,other", "a'b", "a\"b", "a\\b", "a=b", "a(b)", "a:b", "a!b", "a$", "ünïcode",
            String(repeating: "a", count: 33),
        ]
    )
    func invalidNames(name: String) {
        #expect(throws: ScreenISOError.invalidUsername(name)) {
            try SudoersRule.validateUsername(name)
        }
        #expect(throws: ScreenISOError.invalidUsername(name)) {
            try SudoersRule.content(forUser: name)
        }
    }

    @Test("install shell command writes the rule inline and validates the root owned copy before moving it in place")
    func installCommand() throws {
        #expect(
            try SudoersRule.installShellCommand(forUser: "michelebilotta")
                == #"/usr/bin/printf '%s\n' "#
                + "'michelebilotta ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'"
                + " > '/etc/sudoers.d/.screeniso.pending'"
                + " && /usr/sbin/chown root:wheel '/etc/sudoers.d/.screeniso.pending'"
                + " && /bin/chmod 0440 '/etc/sudoers.d/.screeniso.pending'"
                + " && /usr/sbin/visudo -cf '/etc/sudoers.d/.screeniso.pending'"
                + " && /bin/mv -f '/etc/sudoers.d/.screeniso.pending' '/etc/sudoers.d/screeniso'"
                + " || { /bin/rm -f '/etc/sudoers.d/.screeniso.pending'; exit 1; }"
        )
    }

    @Test("install shell command rejects an invalid user")
    func installCommandRejectsInvalidUser() {
        #expect(throws: ScreenISOError.invalidUsername("ALL")) {
            try SudoersRule.installShellCommand(forUser: "ALL")
        }
    }

    @Test("removal shell command")
    func removalCommand() {
        #expect(
            SudoersRule.removalShellCommand()
                == "/bin/rm -f '/etc/sudoers.d/screeniso' '/etc/sudoers.d/.screeniso.pending'"
        )
    }

    @Test("shell quoting survives single quotes and spaces")
    func shellQuoting() {
        #expect(SudoersRule.shellQuoted("/tmp/a b") == "'/tmp/a b'")
        #expect(SudoersRule.shellQuoted("/tmp/it's") == #"'/tmp/it'\''s'"#)
        #expect(SudoersRule.shellQuoted("$(reboot)") == "'$(reboot)'")
    }

    @Test("AppleScript string literal escapes quotes and backslashes")
    func appleScriptEscaping() {
        let shell = #"/bin/echo "a\b" 'c'"#
        #expect(SudoersRule.appleScriptStringLiteral(shell) == #""/bin/echo \"a\\b\" 'c'""#)
        #expect(
            SudoersRule.administratorAppleScript(shellCommand: "/usr/bin/true")
                == #"do shell script "/usr/bin/true" with administrator privileges"#
        )
    }

    @Test("installer runs a single osascript with the rule inline")
    @MainActor
    func installerComposition() async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 0, stdout: "", stderr: ""))
        let installer = AppleScriptSudoersInstaller(runner: runner)

        try await installer.install(forUser: "michelebilotta")

        let commands = await runner.commands
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.executable == "/usr/bin/osascript")
        #expect(command.arguments.count == 2)
        #expect(command.arguments.first == "-e")
        let script = try #require(command.arguments.last)
        #expect(script.hasPrefix(#"do shell script "/usr/bin/printf '%s\\n' 'michelebilotta ALL=(root) NOPASSWD: "#))
        #expect(script.contains("/usr/sbin/visudo -cf '/etc/sudoers.d/.screeniso.pending'"))
        #expect(script.hasSuffix(#"exit 1; }" with administrator privileges"#))
    }

    @Test("installer rejects an invalid user before running anything")
    @MainActor
    func installerRejectsInvalidUser() async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 0, stdout: "", stderr: ""))
        let installer = AppleScriptSudoersInstaller(runner: runner)

        await #expect(throws: ScreenISOError.invalidUsername("ALL")) {
            try await installer.install(forUser: "ALL")
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("a dismissed authorization dialog is reported as cancelled")
    @MainActor
    func installerCancelled() async throws {
        let runner = RecordingCommandRunner(
            output: CommandOutput(exitCode: 1, stdout: "", stderr: "0:120: execution error: User canceled. (-128)\n")
        )
        let installer = AppleScriptSudoersInstaller(runner: runner)

        await #expect(throws: ScreenISOError.authorizationCancelled) {
            try await installer.install(forUser: "michelebilotta")
        }
    }

    @Test("a failed removal fails loud")
    @MainActor
    func removalFailure() async throws {
        let runner = RecordingCommandRunner(output: CommandOutput(exitCode: 1, stdout: "", stderr: "denied"))
        let installer = AppleScriptSudoersInstaller(runner: runner)

        await #expect(throws: ScreenISOError.sudoersRemovalFailed(stderr: "denied")) {
            try await installer.remove()
        }
        let script = try #require(await runner.commands.first?.arguments.last)
        #expect(
            script
                == #"do shell script "/bin/rm -f '/etc/sudoers.d/screeniso' '/etc/sudoers.d/.screeniso.pending'" with administrator privileges"#
        )
    }
}
