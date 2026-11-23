import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@Suite("App version")
struct AppVersionTests {
    @Test("versions compare by number, not as text")
    func ordering() throws {
        let older = try #require(AppVersion("0.9.10"))
        let newer = try #require(AppVersion("0.10.2"))
        #expect(older < newer)
        #expect(try #require(AppVersion("1.0.0")) > newer)
        #expect(AppVersion("0.1.2") == AppVersion("0.1.2"))
        #expect(newer.description == "0.10.2")
    }

    @Test(
        "anything but MAJOR.MINOR.PATCH is rejected",
        arguments: ["", "1.2", "1.2.3.4", "1.2.x", "v1.2.3", "1..3", "-1.2.3", "1.2.3-beta"]
    )
    func rejected(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}

@Suite("App updater")
struct AppUpdaterTests {
    typealias RecordingRunner = ScreenSaverInstallerTests.RecordingRunner

    struct FixedFeed: UpdateFeedFetching {
        var cask: String

        func fetchCask() async throws -> String { cask }
    }

    struct FailingFeed: UpdateFeedFetching {
        func fetchCask() async throws -> String {
            throw AppError.updateCheckFailed(message: "offline")
        }
    }

    static func cask(version: String) -> String {
        """
        cask "screeniso" do
          version "\(version)"
          sha256 "9dc728eb912dcd4df85e03b172140665f4c8d207444183cb4f6ccf3ef8cc67cc"

          url "https://github.com/mbilo126/screen-iso/releases/download/v#{version}/ScreenISO-#{version}.zip"
        end
        """
    }

    static func updater(
        running: String = "0.1.2",
        published: String = "0.1.3",
        runner: RecordingRunner = RecordingRunner(),
        onDisk: String = "0.1.3"
    ) -> AppUpdater {
        AppUpdater(
            runningVersion: running,
            bundlePath: AppUpdater.installedAppPath,
            feed: FixedFeed(cask: cask(version: published)),
            runner: runner,
            fileExists: { _ in true },
            versionOnDisk: { onDisk }
        )
    }

    @Test("a newer version in the tap is offered")
    func newerVersion() async throws {
        #expect(try await Self.updater().availableUpdate() == AppVersion("0.1.3"))
    }

    @Test("the same or an older version is not offered", arguments: ["0.1.2", "0.1.1"])
    func nothingNewer(published: String) async throws {
        #expect(try await Self.updater(published: published).availableUpdate() == nil)
    }

    @Test("a cask without a readable version fails loud")
    func unreadableCask() async {
        var updater = Self.updater()
        updater.feed = FixedFeed(cask: "cask \"screeniso\" do\nend\n")

        await #expect(throws: AppError.updateCheckFailed(message: "il cask nel tap non ha una versione leggibile")) {
            try await updater.availableUpdate()
        }
    }

    @Test("a feed failure reaches the caller")
    func feedFailure() async {
        var updater = Self.updater()
        updater.feed = FailingFeed()

        await #expect(throws: AppError.updateCheckFailed(message: "offline")) {
            try await updater.availableUpdate()
        }
    }

    @Test("a running version that is not MAJOR.MINOR.PATCH fails before the network is used")
    func invalidRunningVersion() async {
        var updater = Self.updater(running: "")
        updater.feed = FailingFeed()

        await #expect(throws: AppError.updateCheckFailed(message: "versione in esecuzione non valida: ")) {
            try await updater.availableUpdate()
        }
    }

    @Test("the update is one brew upgrade of the cask by its full name")
    func install() async throws {
        let runner = RecordingRunner()

        try await Self.updater(runner: runner).install()

        #expect(
            await runner.commands == [["/opt/homebrew/bin/brew", "upgrade", "--cask", "mbilo126/screeniso/screeniso"]]
        )
    }

    @Test("a brew failure carries the end of its error output")
    func brewFailure() async {
        let runner = RecordingRunner(exitCode: 1, stderr: "Error: permission denied\n")

        await #expect(throws: AppError.updateInstallFailed(message: "Error: permission denied")) {
            try await Self.updater(runner: runner).install()
        }
    }

    @Test("brew exiting with 0 without a newer version on disk is a failure")
    func nothingInstalled() async {
        await #expect(
            throws: AppError.updateInstallFailed(message: "brew ha lasciato installata la versione 0.1.2")
        ) {
            try await Self.updater(onDisk: "0.1.2").install()
        }
    }

    @Test("only the copy installed by Homebrew updates itself")
    func managedByHomebrew() {
        var updater = Self.updater()
        #expect(updater.isManagedByHomebrew)

        updater.fileExists = { $0 != AppUpdater.caskroomPath }
        #expect(!updater.isManagedByHomebrew)

        updater.fileExists = { $0 != AppUpdater.brewPath }
        #expect(!updater.isManagedByHomebrew)

        updater.fileExists = { _ in true }
        updater.bundlePath = "/Users/someone/screen-iso/build/ScreenISO.app"
        #expect(!updater.isManagedByHomebrew)
    }

    @Test("the installed version is read from the Info.plist on disk")
    func versionOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenISOTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("ScreenISO.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record(error, "Could not remove \(root.path)")
            }
        }

        #expect(throws: AppError.self) {
            try AppUpdater.readVersion(ofAppAt: app.path)
        }

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "0.1.3"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(try AppUpdater.readVersion(ofAppAt: app.path) == "0.1.3")
    }

    @Test("the notice says that the update restarts the app and what it switches off")
    func notice() throws {
        let version = try #require(AppVersion("0.1.3"))
        #expect(Labels.updateButtonTitle(version) == "Aggiorna alla 0.1.3")
        #expect(Labels.updateNotice(version).contains("0.1.3"))
        #expect(Labels.updateNotice(version).contains("riavvia"))
        #expect(Labels.updateNotice(version).contains("caffeinate"))
    }
}
