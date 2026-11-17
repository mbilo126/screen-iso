import Foundation

public enum ScreenLockPolicy: Equatable, Sendable {
    case immediate
    case delay(seconds: Int)
    case off
    case unrecognized(raw: String)

    /// Only an immediate lock guarantees the session is never left open after the screen locks or the saver starts.
    public var isCompliant: Bool { self == .immediate }
}

extension ScreenLockPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
        case raw
    }

    private enum Kind: String, Codable {
        case immediate
        case delay
        case off
        case unrecognized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .immediate: self = .immediate
        case .delay: self = .delay(seconds: try container.decode(Int.self, forKey: .seconds))
        case .off: self = .off
        case .unrecognized: self = .unrecognized(raw: try container.decode(String.self, forKey: .raw))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .immediate:
            try container.encode(Kind.immediate, forKey: .kind)
        case .delay(let seconds):
            try container.encode(Kind.delay, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .off:
            try container.encode(Kind.off, forKey: .kind)
        case .unrecognized(let raw):
            try container.encode(Kind.unrecognized, forKey: .kind)
            try container.encode(raw, forKey: .raw)
        }
    }
}

public struct ScreenLockPolicyStatus: Codable, Equatable, Sendable {
    public var policy: ScreenLockPolicy
    /// The `sysadminctl` message the policy was parsed from, without the NSLog prefix.
    public var raw: String

    public init(policy: ScreenLockPolicy, raw: String) {
        self.policy = policy
        self.raw = raw
    }
}

/// Parses `sysadminctl -screenLock status`. The message strings come from the macOS 26 `sysadminctl` binary:
/// `screenLock delay is immediate`, `screenLock delay is %d seconds`, `screenLock is off`,
/// `Unknown state for screenLock (%@)`.
public enum ScreenLockStatusParser {
    private static var immediatePattern: Regex<Substring> { /(?i)screenlock\s+delay\s+is\s+immediate/ }
    private static var offPattern: Regex<Substring> { /(?i)screenlock\s+is\s+off/ }
    private static var delayPattern: Regex<(Substring, Substring)> { /(?i)screenlock\s+delay\s+is\s+(\d+)\s+seconds?/ }

    public static func parse(_ output: String) -> ScreenLockPolicyStatus {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let line = lines.first(where: { $0.localizedCaseInsensitiveContains("screenlock") }) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ScreenLockPolicyStatus(policy: .unrecognized(raw: trimmed), raw: trimmed)
        }
        let message = strippingLogPrefix(line)

        if message.firstMatch(of: immediatePattern) != nil {
            return ScreenLockPolicyStatus(policy: .immediate, raw: message)
        }
        if message.firstMatch(of: offPattern) != nil {
            return ScreenLockPolicyStatus(policy: .off, raw: message)
        }
        if let match = message.firstMatch(of: delayPattern), let seconds = Int(match.1) {
            return ScreenLockPolicyStatus(policy: seconds == 0 ? .immediate : .delay(seconds: seconds), raw: message)
        }
        return ScreenLockPolicyStatus(policy: .unrecognized(raw: message), raw: message)
    }

    private static func strippingLogPrefix(_ line: String) -> String {
        // NSLog prepends "date time process[pid:tid] "; the message starts after the first "] ".
        if let range = line.range(of: "] "), line[..<range.lowerBound].contains("[") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
public protocol ScreenLockPolicyProviding: AnyObject {
    func currentPolicy() async throws -> ScreenLockPolicyStatus
}

@MainActor
public final class SysadminctlScreenLockPolicyProvider: ScreenLockPolicyProviding {
    public static let sysadminctlPath = "/usr/sbin/sysadminctl"

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func currentPolicy() async throws -> ScreenLockPolicyStatus {
        let output = try await runner.run(Self.sysadminctlPath, arguments: ["-screenLock", "status"])
        guard output.exitCode == 0 else {
            throw ScreenISOError.commandFailed(
                executable: Self.sysadminctlPath,
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        return ScreenLockStatusParser.parse(output.stderr + "\n" + output.stdout)
    }
}
