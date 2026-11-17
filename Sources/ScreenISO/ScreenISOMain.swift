import Foundation
import ScreenISOCore
import SwiftUI

@main
@MainActor
enum ScreenISOMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(StatusCommand.flag) {
            Task {
                exit(await StatusCommand.run(reader: .live()))
            }
            dispatchMain()
        }
        ScreenISOApp.main()
    }
}

/// `--status`: prints `SystemStatus` as JSON on stdout without starting the UI. Read only.
@MainActor
enum StatusCommand {
    static let flag = "--status"

    static func run(reader: SystemStatusReader) async -> Int32 {
        do {
            let json = try await reader.read().jsonString()
            FileHandle.standardOutput.write(Data((json + "\n").utf8))
            return 0
        } catch {
            let failure = ScreenISOError(error)
            AppLog.app.error("status_command_failed code=\(failure.code, privacy: .public)")
            FileHandle.standardError.write(Data("error: \(failure.code): \(failure.message)\n".utf8))
            return 1
        }
    }
}
