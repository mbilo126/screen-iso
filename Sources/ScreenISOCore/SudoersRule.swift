import Foundation

public enum SudoersRule {
    public static let installPath = "/etc/sudoers.d/screeniso"
    /// sudo skips files in sudoers.d whose name contains a dot, so a half-installed file is never live.
    public static let stagingPath = "/etc/sudoers.d/.screeniso.pending"

    // Lowercase only: an all-caps word would be read by sudo as a User_Alias, and `ALL` as every user.
    private static var usernamePattern: Regex<Substring> { /^[a-z_][a-z0-9_.-]{0,31}$/ }

    public static func validateUsername(_ username: String) throws {
        guard username.wholeMatch(of: usernamePattern) != nil else {
            throw ScreenISOError.invalidUsername(username)
        }
    }

    public static func content(forUser username: String) throws -> String {
        try line(forUser: username) + "\n"
    }

    /// The rule travels inside the command itself: a file written by the user could be swapped before root reads it,
    /// and `visudo` only checks syntax, so any valid rule would be installed.
    public static func installShellCommand(forUser username: String) throws -> String {
        let rule = shellQuoted(try line(forUser: username))
        let staging = shellQuoted(stagingPath)
        let target = shellQuoted(installPath)
        return "/usr/bin/printf '%s\\n' \(rule) > \(staging)"
            + " && /usr/sbin/chown root:wheel \(staging)"
            + " && /bin/chmod 0440 \(staging)"
            + " && /usr/sbin/visudo -cf \(staging)"
            + " && /bin/mv -f \(staging) \(target)"
            + " || { /bin/rm -f \(staging); exit 1; }"
    }

    private static func line(forUser username: String) throws -> String {
        try validateUsername(username)
        return "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    public static func removalShellCommand() -> String {
        "/bin/rm -f \(shellQuoted(installPath)) \(shellQuoted(stagingPath))"
    }

    public static func administratorAppleScript(shellCommand: String) -> String {
        "do shell script \(appleScriptStringLiteral(shellCommand)) with administrator privileges"
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

@MainActor
public protocol SudoersRuleInstalling: AnyObject {
    func install(forUser username: String) async throws
    func remove() async throws
}

/// Installs the rule through a single `osascript` administrator prompt. Never call it from tests.
@MainActor
public final class AppleScriptSudoersInstaller: SudoersRuleInstalling {
    public static let osascriptPath = "/usr/bin/osascript"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public static func osascriptArguments(shellCommand: String) -> [String] {
        ["-e", SudoersRule.administratorAppleScript(shellCommand: shellCommand)]
    }

    public func install(forUser username: String) async throws {
        let command = try SudoersRule.installShellCommand(forUser: username)
        let output = try await runner.run(Self.osascriptPath, arguments: Self.osascriptArguments(shellCommand: command))
        try Self.check(output, failure: ScreenISOError.sudoersInstallFailed(stderr:))
        Log.system.info("sudoers_rule_installed user=\(username, privacy: .public)")
    }

    public func remove() async throws {
        let command = SudoersRule.removalShellCommand()
        let output = try await runner.run(Self.osascriptPath, arguments: Self.osascriptArguments(shellCommand: command))
        try Self.check(output, failure: ScreenISOError.sudoersRemovalFailed(stderr:))
        Log.system.info("sudoers_rule_removed")
    }

    static func check(_ output: CommandOutput, failure: (String) -> ScreenISOError) throws {
        guard output.exitCode != 0 else { return }
        // osascript reports a dismissed authorization dialog as AppleScript error -128.
        if output.stderr.contains("(-128)") {
            Log.system.notice("sudoers_authorization_cancelled")
            throw ScreenISOError.authorizationCancelled
        }
        Log.system.error("sudoers_command_failed stderr=\(output.stderr, privacy: .public)")
        throw failure(output.stderr)
    }
}
