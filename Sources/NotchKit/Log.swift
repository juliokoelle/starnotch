import NotchCore
import os

enum Log {
    static let app = Logger(subsystem: Brand.identifier, category: "app")
    static let wheel = Logger(subsystem: Brand.identifier, category: "wheel")
    static let switcher = Logger(subsystem: Brand.identifier, category: "switcher")
}
