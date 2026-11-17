import Foundation
import Testing

@testable import ScreenISOCore

@MainActor
@Suite("System status")
struct SystemStatusTests {
    @Test("aggregates every probe")
    func aggregates() async throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let saver = directory.file("Screen Savers/ScreenISOSaver.saver")
        try FileManager.default.createDirectory(at: saver, withIntermediateDirectories: true)
        let sudoersRule = directory.file("sudoers.d/screeniso")
        try FileManager.default.createDirectory(
            at: sudoersRule.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: sudoersRule)
        let reader = SystemStatusReader(
            lockPolicy: FakeLockPolicy(.delay(seconds: 300), raw: "screenLock delay is 300 seconds"),
            lidSleep: FakeLidSleep(sleepDisabled: true, sudoRuleActive: false),
            screenLock: FakeScreenLock(),
            biometry: FakeBiometry(available: true),
            screenSaverURL: saver,
            sudoersRuleURL: sudoersRule,
            wallpaperStoreURL: try wallpaperStore(in: directory, mentioning: saver.path)
        )

        let status = try await reader.read()

        #expect(
            status
                == SystemStatus(
                    screenLockPolicy: .delay(seconds: 300),
                    screenLockPolicyRaw: "screenLock delay is 300 seconds",
                    sleepDisabled: true,
                    sudoRuleInstalled: true,
                    lockSymbolResolvable: true,
                    touchIDAvailable: true,
                    screenSaverInstalled: true,
                    screenSaverSelected: true
                )
        )
        #expect(status.screenLockCompliant == false)
    }

    @Test("an unresolvable symbol and a missing saver are reported, not thrown")
    func negativeProbes() async throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let screenLock = FakeScreenLock()
        screenLock.symbolError = .lockSymbolUnavailable(detail: "missing")
        let reader = SystemStatusReader(
            lockPolicy: FakeLockPolicy(),
            lidSleep: FakeLidSleep(),
            screenLock: screenLock,
            biometry: FakeBiometry(available: false),
            screenSaverURL: directory.file("Screen Savers/ScreenISOSaver.saver"),
            sudoersRuleURL: directory.file("sudoers.d/screeniso"),
            wallpaperStoreURL: directory.file("Store/Index.plist")
        )

        let status = try await reader.read()

        #expect(status.lockSymbolResolvable == false)
        #expect(status.screenSaverInstalled == false)
        #expect(status.screenSaverSelected == false)
        #expect(status.sudoRuleInstalled == false)
        #expect(status.touchIDAvailable == false)
        #expect(status.screenLockCompliant)
    }

    @Test("JSON for --status")
    func json() throws {
        let status = SystemStatus(
            screenLockPolicy: .immediate,
            screenLockPolicyRaw: "screenLock delay is immediate",
            sleepDisabled: false,
            sudoRuleInstalled: true,
            lockSymbolResolvable: true,
            touchIDAvailable: false,
            screenSaverInstalled: false,
            screenSaverSelected: false
        )
        let object = try JSONSerialization.jsonObject(with: Data(try status.jsonString().utf8)) as? [String: Any]
        #expect(
            Set(object?.keys.map { $0 } ?? []) == [
                "screenLockPolicy", "screenLockPolicyRaw", "screenLockCompliant", "sleepDisabled", "sudoRuleInstalled",
                "lockSymbolResolvable", "touchIDAvailable", "screenSaverInstalled", "screenSaverSelected",
            ]
        )
        #expect(try JSONCoding.decoder().decode(SystemStatus.self, from: Data(try status.jsonString().utf8)) == status)
    }

    @Test("a store that only mentions other savers reads as not selected")
    func otherSaverSelected() async throws {
        let directory = try TemporaryDirectory()
        defer { removeDirectory(directory) }
        let reader = SystemStatusReader(
            lockPolicy: FakeLockPolicy(),
            lidSleep: FakeLidSleep(),
            screenLock: FakeScreenLock(),
            biometry: FakeBiometry(available: false),
            screenSaverURL: directory.file("Screen Savers/ScreenISOSaver.saver"),
            sudoersRuleURL: directory.file("sudoers.d/screeniso"),
            wallpaperStoreURL: try wallpaperStore(in: directory, mentioning: "/Library/Screen Savers/Other.saver")
        )

        #expect(try await reader.read().screenSaverSelected == false)
    }

    /// Mimics the real store: a binary plist whose saver choice is itself a nested binary plist.
    private func wallpaperStore(in directory: TemporaryDirectory, mentioning path: String) throws -> URL {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["module": ["relative": "file://\(path)"]], format: .binary, options: 0)
        let store = try PropertyListSerialization.data(
            fromPropertyList: ["AllSpacesAndDisplays": ["Idle": ["Configuration": configuration]]],
            format: .binary,
            options: 0
        )
        let url = directory.file("Store/Index.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.write(to: url)
        return url
    }

    private func removeDirectory(_ directory: TemporaryDirectory) {
        do {
            try directory.remove()
        } catch {
            Issue.record(error)
        }
    }
}
