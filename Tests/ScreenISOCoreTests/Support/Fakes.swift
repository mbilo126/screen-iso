import Foundation

@testable import ScreenISOCore

@MainActor
final class FakePowerAssertions: PowerAssertionManaging {
    private(set) var heldKinds: Set<PowerAssertionKind> = []
    private(set) var acquireCalls: [PowerAssertionKind] = []
    private(set) var releaseCalls: [PowerAssertionKind] = []
    var acquireError: ScreenISOError?
    var failingAcquires: Set<PowerAssertionKind> = []
    /// Kinds whose release fails. Like the real manager, the fake stops tracking them anyway.
    var failingReleases: Set<PowerAssertionKind> = []

    func acquire(_ kind: PowerAssertionKind, reason: String) throws {
        acquireCalls.append(kind)
        if let acquireError {
            throw acquireError
        }
        if failingAcquires.contains(kind) {
            throw ScreenISOError.powerAssertionCreateFailed(kind: kind, ioReturn: -1)
        }
        heldKinds.insert(kind)
    }

    func release(_ kind: PowerAssertionKind) throws {
        releaseCalls.append(kind)
        heldKinds.remove(kind)
        if failingReleases.contains(kind) {
            throw ScreenISOError.powerAssertionReleaseFailed(kind: kind, ioReturn: -1)
        }
    }
}

@MainActor
final class FakeLidSleep: LidSleepControlling {
    var sleepDisabled: Bool
    var sudoRuleActive: Bool
    private(set) var setCalls: [Bool] = []
    /// Values for which `setSleepDisabled` fails.
    var failingSetValues: Set<Bool> = []

    init(sleepDisabled: Bool = false, sudoRuleActive: Bool = true) {
        self.sleepDisabled = sleepDisabled
        self.sudoRuleActive = sudoRuleActive
    }

    func isSleepDisabled() async throws -> Bool { sleepDisabled }

    func setSleepDisabled(_ disabled: Bool) async throws {
        setCalls.append(disabled)
        if failingSetValues.contains(disabled) {
            throw ScreenISOError.commandFailed(executable: "/usr/bin/sudo", exitCode: 1, stderr: "denied")
        }
        sleepDisabled = disabled
    }

    func isSudoRuleActive() async throws -> Bool { sudoRuleActive }
}

@MainActor
final class FakeLockPolicy: ScreenLockPolicyProviding {
    var status: ScreenLockPolicyStatus

    init(_ policy: ScreenLockPolicy = .immediate, raw: String = "screenLock delay is immediate") {
        status = ScreenLockPolicyStatus(policy: policy, raw: raw)
    }

    func currentPolicy() async throws -> ScreenLockPolicyStatus { status }
}

@MainActor
final class FakeScreenLock: ScreenLockControlling {
    var locked = false
    var lockNowLocks = true
    var screenSaverLocks = true
    var screenSaverError: ScreenISOError?
    var symbolError: ScreenISOError?
    private(set) var lockNowCalls = 0
    private(set) var screenSaverCalls = 0
    private(set) var lockChecks = 0

    @discardableResult
    func lockNow() throws -> Int32 {
        lockNowCalls += 1
        if let symbolError {
            throw symbolError
        }
        if lockNowLocks {
            locked = true
        }
        return 0
    }

    func startScreenSaver() async throws {
        screenSaverCalls += 1
        if let screenSaverError {
            throw screenSaverError
        }
        if screenSaverLocks {
            locked = true
        }
    }

    func isScreenLocked() throws -> Bool {
        lockChecks += 1
        return locked
    }

    func verifyLockSymbol() throws {
        if let symbolError {
            throw symbolError
        }
    }
}

@MainActor
final class FakeLockEvents: ScreenLockEventObserving {
    private var handler: (@MainActor (ScreenLockEvent) async -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    var isObserving: Bool { handler != nil }

    func startObserving(_ handler: @escaping @MainActor (ScreenLockEvent) async -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stopObserving() {
        stopCount += 1
        handler = nil
    }

    func emit(_ event: ScreenLockEvent) async {
        await handler?(event)
    }
}

struct FakeBiometry: BiometryChecking {
    var available: Bool

    func isTouchIDAvailable() -> Bool { available }
}

struct RecordedCommand: Equatable, Sendable {
    var executable: String
    var arguments: [String]
}

actor RecordingCommandRunner: CommandRunning {
    private(set) var commands: [RecordedCommand] = []
    private let respond: @Sendable (RecordedCommand) -> CommandOutput

    init(respond: @escaping @Sendable (RecordedCommand) -> CommandOutput) {
        self.respond = respond
    }

    init(output: CommandOutput) {
        self.respond = { _ in output }
    }

    func run(_ executable: String, arguments: [String]) async throws -> CommandOutput {
        let command = RecordedCommand(executable: executable, arguments: arguments)
        commands.append(command)
        return respond(command)
    }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenISOCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}
