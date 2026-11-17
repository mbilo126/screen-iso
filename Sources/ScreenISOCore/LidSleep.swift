import Foundation

public enum PmsetOutputParser {
    /// Reads the `SleepDisabled` value from `pmset -g`. A missing line means the default, 0.
    public static func sleepDisabled(from output: String) throws -> Bool {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2 else {
                throw ScreenISOError.pmsetOutputUnparseable(line: String(rawLine))
            }
            switch fields[1] {
            case "0": return false
            case "1": return true
            default: throw ScreenISOError.pmsetOutputUnparseable(line: String(rawLine))
            }
        }
        return false
    }
}

/// Controls `pmset disablesleep`, which keeps the Mac awake with the lid closed.
@MainActor
public protocol LidSleepControlling: AnyObject {
    func isSleepDisabled() async throws -> Bool
    func setSleepDisabled(_ disabled: Bool) async throws
    /// True when the sudoers rule lets the current user run both `pmset -a disablesleep` variants without a password.
    func isSudoRuleActive() async throws -> Bool
}

@MainActor
public final class PmsetLidSleepController: LidSleepControlling {
    public static let pmsetPath = "/usr/bin/pmset"
    public static let sudoPath = "/usr/bin/sudo"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public static func setArguments(disabled: Bool) -> [String] {
        ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
    }

    public static func checkArguments(disabled: Bool) -> [String] {
        ["-n", "-l", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
    }

    public func isSleepDisabled() async throws -> Bool {
        let output = try await runner.run(Self.pmsetPath, arguments: ["-g"])
        guard output.exitCode == 0 else {
            throw ScreenISOError.commandFailed(
                executable: Self.pmsetPath,
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        return try PmsetOutputParser.sleepDisabled(from: output.stdout)
    }

    public func setSleepDisabled(_ disabled: Bool) async throws {
        let output = try await runner.run(Self.sudoPath, arguments: Self.setArguments(disabled: disabled))
        guard output.exitCode == 0 else {
            Log.system.error(
                "disable_sleep_set_failed value=\(disabled) exitCode=\(output.exitCode) stderr=\(output.stderr, privacy: .public)"
            )
            throw ScreenISOError.commandFailed(
                executable: Self.sudoPath,
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        Log.system.info("disable_sleep_set value=\(disabled)")
    }

    public func isSudoRuleActive() async throws -> Bool {
        for value in [true, false] {
            let output = try await runner.run(Self.sudoPath, arguments: Self.checkArguments(disabled: value))
            if output.exitCode != 0 {
                return false
            }
        }
        return true
    }
}
