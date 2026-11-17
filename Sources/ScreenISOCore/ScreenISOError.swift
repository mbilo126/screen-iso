import Foundation

public enum ScreenISOError: Error, Equatable, Sendable {
    case commandLaunchFailed(executable: String, message: String)
    case commandFailed(executable: String, exitCode: Int32, stderr: String)
    case pmsetOutputUnparseable(line: String)
    case invalidUsername(String)
    case authorizationCancelled
    case sudoersInstallFailed(stderr: String)
    case sudoersRemovalFailed(stderr: String)
    case lockSymbolUnavailable(detail: String)
    case screenSaverLaunchFailed(message: String)
    case sessionInfoUnavailable
    case powerAssertionCreateFailed(kind: PowerAssertionKind, ioReturn: Int32)
    case powerAssertionReleaseFailed(kind: PowerAssertionKind, ioReturn: Int32)
    case screenLockNotImmediate(ScreenLockPolicy)
    case sudoRuleMissing
    case lockNotConfirmed(lockMode: LockMode)
    case sessionAlreadyRunning
    case noActiveSession
    case fileWriteFailed(path: String, message: String)
    case fileReadFailed(path: String, message: String)
    case snapshotCorrupted(path: String, message: String)
    case cleanupIncomplete([ScreenISOError])
    case unexpected(message: String)

    public var code: String {
        switch self {
        case .commandLaunchFailed: "command_launch_failed"
        case .commandFailed: "command_failed"
        case .pmsetOutputUnparseable: "pmset_output_unparseable"
        case .invalidUsername: "invalid_username"
        case .authorizationCancelled: "authorization_cancelled"
        case .sudoersInstallFailed: "sudoers_install_failed"
        case .sudoersRemovalFailed: "sudoers_removal_failed"
        case .lockSymbolUnavailable: "lock_symbol_unavailable"
        case .screenSaverLaunchFailed: "screen_saver_launch_failed"
        case .sessionInfoUnavailable: "session_info_unavailable"
        case .powerAssertionCreateFailed: "power_assertion_create_failed"
        case .powerAssertionReleaseFailed: "power_assertion_release_failed"
        case .screenLockNotImmediate: "screen_lock_not_immediate"
        case .sudoRuleMissing: "sudo_rule_missing"
        case .lockNotConfirmed: "lock_not_confirmed"
        case .sessionAlreadyRunning: "session_already_running"
        case .noActiveSession: "no_active_session"
        case .fileWriteFailed: "file_write_failed"
        case .fileReadFailed: "file_read_failed"
        case .snapshotCorrupted: "snapshot_corrupted"
        case .cleanupIncomplete: "cleanup_incomplete"
        case .unexpected: "unexpected_error"
        }
    }

    public var message: String {
        switch self {
        case .commandLaunchFailed(let executable, let message):
            "Could not launch \(executable): \(message)"
        case .commandFailed(let executable, let exitCode, let stderr):
            "\(executable) exited with status \(exitCode): \(stderr)"
        case .pmsetOutputUnparseable(let line):
            "Unexpected SleepDisabled line in pmset output: \(line)"
        case .invalidUsername(let name):
            "Not a valid POSIX user name: \(name)"
        case .authorizationCancelled:
            "The administrator authorization was cancelled"
        case .sudoersInstallFailed(let stderr):
            "Installing the sudoers rule failed: \(stderr)"
        case .sudoersRemovalFailed(let stderr):
            "Removing the sudoers rule failed: \(stderr)"
        case .lockSymbolUnavailable(let detail):
            "SACLockScreenImmediate is not available: \(detail)"
        case .screenSaverLaunchFailed(let message):
            "Could not start ScreenSaverEngine: \(message)"
        case .sessionInfoUnavailable:
            "No graphical login session is available"
        case .powerAssertionCreateFailed(let kind, let ioReturn):
            "IOPMAssertionCreateWithName failed for \(kind.assertionType) with IOReturn \(ioReturn)"
        case .powerAssertionReleaseFailed(let kind, let ioReturn):
            "IOPMAssertionRelease failed for \(kind.assertionType) with IOReturn \(ioReturn)"
        case .screenLockNotImmediate(let policy):
            "The screen lock policy is not immediate: \(policy)"
        case .sudoRuleMissing:
            "The sudoers rule for pmset disablesleep is not active"
        case .lockNotConfirmed(let lockMode):
            "The screen lock could not be confirmed (lock mode \(lockMode.rawValue))"
        case .sessionAlreadyRunning:
            "A protected session is already running"
        case .noActiveSession:
            "There is no active protected session"
        case .fileWriteFailed(let path, let message):
            "Could not write \(path): \(message)"
        case .fileReadFailed(let path, let message):
            "Could not read \(path): \(message)"
        case .snapshotCorrupted(let path, let message):
            "The session snapshot at \(path) is not valid: \(message)"
        case .cleanupIncomplete(let errors):
            "Cleanup did not complete: " + errors.map(\.code).joined(separator: ", ")
        case .unexpected(let message):
            "Unexpected error: \(message)"
        }
    }
}

extension ScreenISOError: LocalizedError {
    public var errorDescription: String? { message }
}

extension ScreenISOError {
    /// Wraps errors that do not come from ScreenISOCore, such as `CancellationError`, so state stays typed.
    public init(_ error: any Error) {
        if let error = error as? ScreenISOError {
            self = error
        } else {
            self = .unexpected(message: String(describing: error))
        }
    }

    /// Collapses several cleanup failures into one error.
    static func combining(_ errors: [ScreenISOError]) -> ScreenISOError? {
        switch errors.count {
        case 0: nil
        case 1: errors[0]
        default: .cleanupIncomplete(errors)
        }
    }
}
