import os

enum AppLog {
    static let subsystem = "it.yellowtech.screeniso"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let configuration = Logger(subsystem: subsystem, category: "configuration")
}
