import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@Suite("Labels")
struct LabelsTests {
    @Test("each power assertion shows its caffeinate flag", arguments: PowerAssertionKind.allCases)
    func caffeinateFlag(_ kind: PowerAssertionKind) {
        #expect(Labels.title(of: kind).hasSuffix("(caffeinate \(kind.caffeinateFlag))"))
    }

    @Test("screen lock policies are described in Italian")
    func policies() {
        #expect(Labels.description(of: .immediate) == "subito")
        #expect(Labels.description(of: .delay(seconds: 1)) == "dopo 1 secondo")
        #expect(Labels.description(of: .delay(seconds: 300)) == "dopo 300 secondi")
        #expect(Labels.description(of: .off) == "password non richiesta")
        #expect(Labels.description(of: .unrecognized(raw: "???")) == "non riconosciuta (???)")
    }
}

@Suite("Screen saver installer")
@MainActor
struct ScreenSaverInstallerTests {
    final class Sandbox {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenISOTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func fakeBundle(withSaver: Bool) throws -> Bundle {
            let bundleURL = root.appendingPathComponent("Fake.bundle", isDirectory: true)
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            if withSaver {
                let saver = resources.appendingPathComponent("ScreenISOSaver.saver/Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: saver, withIntermediateDirectories: true)
                try Data("plist".utf8).write(to: saver.appendingPathComponent("Info.plist"))
            }
            return try #require(Bundle(url: bundleURL))
        }

        var destination: URL {
            root.appendingPathComponent("Screen Savers/ScreenISOSaver.saver", isDirectory: true)
        }

        func cleanUp() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record(error, "Could not remove \(root.path)")
            }
        }
    }

    actor RecordingRunner: CommandRunning {
        private(set) var commands: [[String]] = []
        private let output: CommandOutput

        init(exitCode: Int32 = 0, stderr: String = "") {
            output = CommandOutput(exitCode: exitCode, stdout: "", stderr: stderr)
        }

        func run(_ executable: String, arguments: [String]) async throws -> CommandOutput {
            commands.append([executable] + arguments)
            return output
        }
    }

    @Test("a first install copies the bundled saver and leaves the host alone")
    func installs() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let runner = RecordingRunner()
        let installer = ScreenSaverInstaller(
            bundle: try sandbox.fakeBundle(withSaver: true),
            destination: sandbox.destination,
            runner: runner
        )

        try await installer.install()

        let copied = sandbox.destination.appendingPathComponent("Contents/Info.plist")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try installer.isInstalledCopyCurrent())
        #expect(await runner.commands.isEmpty)
        #expect(try stagedCopies(in: sandbox).isEmpty)
    }

    @Test("a bundle without the saver fails with saver_resource_missing")
    func missingResource() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let installer = ScreenSaverInstaller(
            bundle: try sandbox.fakeBundle(withSaver: false),
            destination: sandbox.destination,
            runner: RecordingRunner()
        )

        await #expect(throws: AppError.saverResourceMissing) {
            try await installer.install()
        }
        #expect(throws: AppError.saverResourceMissing) {
            try installer.isInstalledCopyCurrent()
        }
    }

    @Test("an older installed copy is detected, replaced, and the host is restarted")
    func updatesExistingCopy() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let runner = RecordingRunner()
        let bundle = try sandbox.fakeBundle(withSaver: true)
        let installer = ScreenSaverInstaller(bundle: bundle, destination: sandbox.destination, runner: runner)
        try await installer.install()

        let bundledPlist = try #require(bundle.url(forResource: "ScreenISOSaver", withExtension: "saver"))
            .appendingPathComponent("Contents/Info.plist")
        try Data("newer plist".utf8).write(to: bundledPlist)
        #expect(try installer.isInstalledCopyCurrent() == false)

        try await installer.install()

        let installedPlist = sandbox.destination.appendingPathComponent("Contents/Info.plist")
        #expect(try Data(contentsOf: installedPlist) == Data("newer plist".utf8))
        #expect(try installer.isInstalledCopyCurrent())
        #expect(
            await runner.commands == [["/usr/bin/pkill"] + ScreenSaverInstaller.hostReloadArguments()]
        )
        #expect(try stagedCopies(in: sandbox).isEmpty)
    }

    @Test("the host is matched by exact name and limited to the current user")
    func hostReloadArguments() {
        #expect(ScreenSaverInstaller.hostReloadArguments(userID: 502) == ["-U", "502", "-x", "legacyScreenSaver"])
    }

    @Test("no running host is not an error, any other pkill failure is")
    func hostReloadExitCodes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let bundle = try sandbox.fakeBundle(withSaver: true)

        try await ScreenSaverInstaller(
            bundle: bundle, destination: sandbox.destination, runner: RecordingRunner(exitCode: 1)
        ).reloadHost()

        await #expect(throws: AppError.saverHostReloadFailed(message: "denied")) {
            try await ScreenSaverInstaller(
                bundle: bundle, destination: sandbox.destination, runner: RecordingRunner(exitCode: 3, stderr: "denied")
            ).reloadHost()
        }
    }

    private func stagedCopies(in sandbox: Sandbox) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: sandbox.destination.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".") }
    }
}

@Suite("Screen saver settings pane")
struct ScreenSaverSettingsPaneTests {
    @Test("macOS 26 and later choose the screen saver inside Wallpaper", arguments: [26, 27])
    func wallpaperPane(osMajorVersion: Int) {
        let pane = ScreenSaverSettingsPane(osMajorVersion: osMajorVersion)
        #expect(pane == .wallpaper)
        #expect(pane.url == "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        #expect(pane.openButtonTitle == "Apri Impostazioni Sfondo")
        #expect(pane.selectionHint.contains("Sfondo"))
    }

    @Test("earlier versions have a Screen Saver pane of their own", arguments: [14, 15])
    func screenSaverPane(osMajorVersion: Int) {
        let pane = ScreenSaverSettingsPane(osMajorVersion: osMajorVersion)
        #expect(pane == .screenSaver)
        #expect(pane.url == "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")
        #expect(pane.openButtonTitle == "Apri Impostazioni Salvaschermo")
    }
}
