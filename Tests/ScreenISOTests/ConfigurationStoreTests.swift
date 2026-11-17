import Foundation
import ScreenISOCore
import Testing

@testable import ScreenISO

@MainActor
final class InMemoryDefaults: DataDefaults {
    private(set) var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }
}

@Suite("Configuration store")
@MainActor
struct ConfigurationStoreTests {
    @Test("nothing saved yields the default configuration")
    func defaultWhenEmpty() throws {
        let store = ConfigurationStore(defaults: InMemoryDefaults())
        #expect(try store.load() == .default)
    }

    @Test("a saved configuration round-trips")
    func roundTrip() throws {
        let defaults = InMemoryDefaults()
        let configuration = SessionConfiguration(
            powerAssertions: [.preventDisplaySleep, .preventDiskIdle],
            keepAwakeWithLidClosed: true,
            lockMode: .screenSaver
        )
        try ConfigurationStore(defaults: defaults).save(configuration)

        #expect(try ConfigurationStore(defaults: defaults).load() == configuration)
    }

    @Test("an empty assertion set is kept, not replaced by the default")
    func emptyAssertions() throws {
        let defaults = InMemoryDefaults()
        let configuration = SessionConfiguration(powerAssertions: [])
        let store = ConfigurationStore(defaults: defaults)
        try store.save(configuration)

        #expect(try store.load().powerAssertions.isEmpty)
    }

    @Test("unreadable data throws instead of silently falling back")
    func corruptedData() {
        let defaults = InMemoryDefaults()
        defaults.set(Data("{\"lockMode\":\"teleport\"}".utf8), forKey: ConfigurationStore.key)
        let store = ConfigurationStore(defaults: defaults)

        #expect {
            try store.load()
        } throws: { error in
            (error as? AppError)?.code == "configuration_unreadable"
        }
    }
}
