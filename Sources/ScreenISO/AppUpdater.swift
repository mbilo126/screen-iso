import Foundation
import ScreenISOCore

/// A `MAJOR.MINOR.PATCH` version, the only format `scripts/release.sh` publishes.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

protocol UpdateFeedFetching: Sendable {
    /// The text of the cask published in the Homebrew tap.
    func fetchCask() async throws -> String
}

/// Reads the cask from the tap: the version written there is exactly the one `brew upgrade` installs.
struct TapFeed: UpdateFeedFetching {
    static let url = "https://raw.githubusercontent.com/mbilo126/homebrew-screeniso/HEAD/Casks/screeniso.rb"
    static let timeout: TimeInterval = 20

    func fetchCask() async throws -> String {
        guard let url = URL(string: Self.url) else {
            throw AppError.updateCheckFailed(message: Self.url)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("ScreenISO", forHTTPHeaderField: "User-Agent")
        // Ephemeral: the check leaves no cookies and no cache on disk.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.updateCheckFailed(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.updateCheckFailed(message: "risposta non HTTP")
        }
        guard http.statusCode == 200 else {
            throw AppError.updateCheckFailed(message: "HTTP \(http.statusCode)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Checks the tap for a newer version and installs it with Homebrew. Nothing is installed without a request:
/// the update replaces the app and needs a restart, which releases the power assertions.
struct AppUpdater: Sendable {
    static let brewPath = "/opt/homebrew/bin/brew"
    static let caskroomPath = "/opt/homebrew/Caskroom/screeniso"
    static let caskName = "mbilo126/screeniso/screeniso"
    static let installedAppPath = "/Applications/ScreenISO.app"
    static let errorDetailLimit = 300

    var runningVersion: String = AppUpdater.bundleVersion
    var bundlePath: String = Bundle.main.bundlePath
    var feed: any UpdateFeedFetching = TapFeed()
    var runner: any CommandRunning = ProcessCommandRunner()
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var versionOnDisk: @Sendable () throws -> String = { try AppUpdater.readVersion(ofAppAt: installedAppPath) }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// True for the copy Homebrew installed. A copy built from source is left alone: `brew` does not know it.
    var isManagedByHomebrew: Bool {
        bundlePath == Self.installedAppPath && fileExists(Self.brewPath) && fileExists(Self.caskroomPath)
    }

    static func caskVersion(in cask: String) -> AppVersion? {
        let prefix = "version \""
        for line in cask.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("\""), trimmed.count > prefix.count else { continue }
            return AppVersion(String(trimmed.dropFirst(prefix.count).dropLast()))
        }
        return nil
    }

    /// The version in the tap when it is newer than the running one.
    func availableUpdate() async throws -> AppVersion? {
        guard let running = AppVersion(runningVersion) else {
            throw AppError.updateCheckFailed(message: "versione in esecuzione non valida: \(runningVersion)")
        }
        let cask = try await feed.fetchCask()
        guard let published = Self.caskVersion(in: cask) else {
            throw AppError.updateCheckFailed(message: "il cask nel tap non ha una versione leggibile")
        }
        return published > running ? published : nil
    }

    /// Runs `brew upgrade` for the cask. Started from inside the app, `brew` does not quit it: the caller restarts.
    func install() async throws {
        let output = try await runner.run(Self.brewPath, arguments: ["upgrade", "--cask", Self.caskName])
        guard output.exitCode == 0 else {
            throw AppError.updateInstallFailed(message: Self.lastLines(of: output.stderr))
        }
        // `brew` also exits with 0 when it finds nothing to upgrade.
        let installed = try versionOnDisk()
        guard let installedVersion = AppVersion(installed), let running = AppVersion(runningVersion),
            installedVersion > running
        else {
            throw AppError.updateInstallFailed(message: "brew ha lasciato installata la versione \(installed)")
        }
    }

    static func readVersion(ofAppAt path: String) throws -> String {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        } catch {
            throw AppError.updateInstallFailed(message: "\(url.path). \(error.localizedDescription)")
        }
        guard let version = (plist as? [String: Any])?["CFBundleShortVersionString"] as? String else {
            throw AppError.updateInstallFailed(message: "\(url.path) non ha una versione")
        }
        return version
    }

    static func lastLines(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(errorDetailLimit))
    }
}
