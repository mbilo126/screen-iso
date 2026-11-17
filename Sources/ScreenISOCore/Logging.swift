import os

enum Log {
    static let subsystem = "it.yellowtech.screeniso"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let lock = Logger(subsystem: subsystem, category: "lock")
    static let audit = Logger(subsystem: subsystem, category: "audit")
    static let system = Logger(subsystem: subsystem, category: "system")
}
