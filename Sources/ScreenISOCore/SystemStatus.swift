import Foundation
import LocalAuthentication

public struct SystemStatus: Codable, Equatable, Sendable {
    public var screenLockPolicy: ScreenLockPolicy
    public var screenLockPolicyRaw: String
    public var screenLockCompliant: Bool
    public var sleepDisabled: Bool
    public var sudoRuleInstalled: Bool
    public var lockSymbolResolvable: Bool
    public var touchIDAvailable: Bool
    public var screenSaverInstalled: Bool
    /// Best effort: true when the system wallpaper store mentions the ScreenISO saver.
    public var screenSaverSelected: Bool

    public init(
        screenLockPolicy: ScreenLockPolicy,
        screenLockPolicyRaw: String,
        sleepDisabled: Bool,
        sudoRuleInstalled: Bool,
        lockSymbolResolvable: Bool,
        touchIDAvailable: Bool,
        screenSaverInstalled: Bool,
        screenSaverSelected: Bool
    ) {
        self.screenLockPolicy = screenLockPolicy
        self.screenLockPolicyRaw = screenLockPolicyRaw
        self.screenLockCompliant = screenLockPolicy.isCompliant
        self.sleepDisabled = sleepDisabled
        self.sudoRuleInstalled = sudoRuleInstalled
        self.lockSymbolResolvable = lockSymbolResolvable
        self.touchIDAvailable = touchIDAvailable
        self.screenSaverInstalled = screenSaverInstalled
        self.screenSaverSelected = screenSaverSelected
    }

    /// Sorted, pretty-printed JSON for `--status`.
    public func jsonString() throws -> String {
        let encoder = JSONCoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public protocol BiometryChecking: Sendable {
    func isTouchIDAvailable() -> Bool
}

public struct LocalAuthenticationBiometryChecker: BiometryChecking {
    public init() {}

    public func isTouchIDAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if let error {
            Log.system.info(
                "touch_id_unavailable code=\(error.code) reason=\(error.localizedDescription, privacy: .public)")
        }
        return available
    }
}

@MainActor
public final class SystemStatusReader {
    public static var defaultScreenSaverURL: URL {
        FileLocations.home.appendingPathComponent("Library/Screen Savers/ScreenISOSaver.saver")
    }

    private let lockPolicy: any ScreenLockPolicyProviding
    private let lidSleep: any LidSleepControlling
    private let screenLock: any ScreenLockControlling
    private let biometry: any BiometryChecking
    public static var defaultWallpaperStoreURL: URL {
        FileLocations.home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private let screenSaverURL: URL
    private let sudoersRuleURL: URL
    private let wallpaperStoreURL: URL

    public init(
        lockPolicy: any ScreenLockPolicyProviding,
        lidSleep: any LidSleepControlling,
        screenLock: any ScreenLockControlling,
        biometry: any BiometryChecking,
        screenSaverURL: URL = SystemStatusReader.defaultScreenSaverURL,
        sudoersRuleURL: URL = URL(fileURLWithPath: SudoersRule.installPath),
        wallpaperStoreURL: URL = SystemStatusReader.defaultWallpaperStoreURL
    ) {
        self.lockPolicy = lockPolicy
        self.lidSleep = lidSleep
        self.screenLock = screenLock
        self.biometry = biometry
        self.screenSaverURL = screenSaverURL
        self.sudoersRuleURL = sudoersRuleURL
        self.wallpaperStoreURL = wallpaperStoreURL
    }

    public static func live() -> SystemStatusReader {
        let runner = ProcessCommandRunner()
        return SystemStatusReader(
            lockPolicy: SysadminctlScreenLockPolicyProvider(runner: runner),
            lidSleep: PmsetLidSleepController(runner: runner),
            screenLock: SystemScreenLockController(),
            biometry: LocalAuthenticationBiometryChecker()
        )
    }

    public func read() async throws -> SystemStatus {
        let policy = try await lockPolicy.currentPolicy()
        let sleepDisabled = try await lidSleep.isSleepDisabled()
        // A file check, not `sudo -n -l`: status is read often, and every denied sudo probe lands in the system log.
        let sudoRuleInstalled = FileManager.default.fileExists(atPath: sudoersRuleURL.path)

        let lockSymbolResolvable: Bool
        do {
            try screenLock.verifyLockSymbol()
            lockSymbolResolvable = true
        } catch {
            Log.lock.error("lock_symbol_unresolvable error=\(ScreenISOError(error).message, privacy: .public)")
            lockSymbolResolvable = false
        }

        var isDirectory: ObjCBool = false
        let saverExists = FileManager.default.fileExists(atPath: screenSaverURL.path, isDirectory: &isDirectory)

        return SystemStatus(
            screenLockPolicy: policy.policy,
            screenLockPolicyRaw: policy.raw,
            sleepDisabled: sleepDisabled,
            sudoRuleInstalled: sudoRuleInstalled,
            lockSymbolResolvable: lockSymbolResolvable,
            touchIDAvailable: biometry.isTouchIDAvailable(),
            screenSaverInstalled: saverExists && isDirectory.boolValue,
            screenSaverSelected: isScreenSaverSelected()
        )
    }

    /// The screen saver choice lives in a private, undocumented store. Searching the raw bytes for the bundle name
    /// survives layout changes; a missing or unreadable store reads as "not selected".
    private func isScreenSaverSelected() -> Bool {
        let store: Data
        do {
            store = try Data(contentsOf: wallpaperStoreURL)
        } catch {
            Log.system.error("wallpaper_store_unreadable error=\(error.localizedDescription, privacy: .public)")
            return false
        }
        let bundleName = screenSaverURL.deletingPathExtension().lastPathComponent
        return [String.Encoding.utf8, .utf16BigEndian].contains { encoding in
            guard let needle = bundleName.data(using: encoding) else { return false }
            return store.range(of: needle) != nil
        }
    }
}
