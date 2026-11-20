import AppKit
import CoreGraphics
import Foundation

public enum LockMode: String, Codable, CaseIterable, Sendable {
    /// `SACLockScreenImmediate`: the loginwindow lock screen.
    case loginWindow
    /// ScreenSaverEngine, which locks through the immediate screen lock policy.
    case screenSaver
}

public enum LockMethod: String, Codable, Sendable {
    case loginWindow
    case screenSaver
    /// The screen saver did not confirm the lock and `SACLockScreenImmediate` did.
    case loginWindowFallback
}

@MainActor
public protocol ScreenLockControlling: AnyObject {
    /// Locks through `SACLockScreenImmediate` and returns its raw result.
    @discardableResult
    func lockNow() throws -> Int32
    func startScreenSaver() async throws
    func isScreenLocked() throws -> Bool
    /// Resolves `SACLockScreenImmediate` without calling it.
    func verifyLockSymbol() throws
}

@MainActor
public final class SystemScreenLockController: ScreenLockControlling {
    public static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    public static let lockSymbolName = "SACLockScreenImmediate"
    public static let screenSaverEnginePath = "/System/Library/CoreServices/ScreenSaverEngine.app"
    public static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    private typealias LockFunction = @convention(c) () -> Int32

    public init() {}

    @discardableResult
    public func lockNow() throws -> Int32 {
        let lock = try resolveLockFunction()
        let result = lock()
        Log.lock.info("lock_now_called result=\(result)")
        return result
    }

    public func startScreenSaver() async throws {
        let url = URL(fileURLWithPath: Self.screenSaverEnginePath)
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            Log.lock.info("screen_saver_started")
        } catch {
            Log.lock.error("screen_saver_start_failed error=\(error.localizedDescription, privacy: .public)")
            throw ScreenISOError.screenSaverLaunchFailed(message: error.localizedDescription)
        }
    }

    public func isScreenLocked() throws -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            throw ScreenISOError.sessionInfoUnavailable
        }
        // The key is only present while the session is locked.
        return (session[Self.screenIsLockedKey] as? Bool) ?? false
    }

    public func verifyLockSymbol() throws {
        _ = try resolveLockFunction()
    }

    private func resolveLockFunction() throws -> LockFunction {
        guard let handle = dlopen(Self.loginFrameworkPath, RTLD_LAZY) else {
            throw ScreenISOError.lockSymbolUnavailable(detail: Self.lastDynamicLinkerError())
        }
        guard let symbol = dlsym(handle, Self.lockSymbolName) else {
            throw ScreenISOError.lockSymbolUnavailable(detail: Self.lastDynamicLinkerError())
        }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }

    private static func lastDynamicLinkerError() -> String {
        guard let message = dlerror() else { return "unknown dynamic linker error" }
        return String(cString: message)
    }
}

public enum ScreenLockEvent: String, Codable, Sendable {
    case locked
    case unlocked
}

@MainActor
public protocol ScreenLockEventObserving: AnyObject {
    func startObserving(_ handler: @escaping @MainActor (ScreenLockEvent) async -> Void)
    func stopObserving()
}

@MainActor
public final class DistributedScreenLockObserver: ScreenLockEventObserving {
    public static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    public static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let center: DistributedNotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    public init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    public func startObserving(_ handler: @escaping @MainActor (ScreenLockEvent) async -> Void) {
        stopObserving()
        let pairs: [(Notification.Name, ScreenLockEvent)] = [
            (Self.lockedNotification, .locked),
            (Self.unlockedNotification, .unlocked),
        ]
        for (name, event) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Log.lock.info("screen_lock_notification event=\(event.rawValue, privacy: .public)")
                Task { @MainActor in await handler(event) }
            }
            tokens.append(token)
        }
    }

    public func stopObserving() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}
