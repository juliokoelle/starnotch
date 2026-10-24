import Foundation

/// A value from `config.toml`.
public enum ConfigValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ConfigValue])
}

/// The app's configuration file, `~/Library/Application Support/<App>/config.toml`: paths,
/// connectors, the character pack, the API port. Read once at launch.
///
/// A small TOML subset, enough for settings: `[section]` and `[section.sub]` tables,
/// `key = value` with strings (basic and literal), integers, floats, booleans and one-line
/// arrays of those, `#` comments. Anything else is an error with its line number.
public struct NotchConfig: Equatable, Sendable {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "config.toml line \(line): \(message)" }
    }

    /// Section name ("" for keys before the first table) to its keys.
    public var sections: [String: [String: ConfigValue]]

    public init(sections: [String: [String: ConfigValue]] = [:]) {
        self.sections = sections
    }

    public subscript(_ section: String) -> ConfigSection {
        ConfigSection(name: section, values: sections[section] ?? [:])
    }

    /// Keys of `other` win; sections merge key by key.
    public mutating func merge(_ other: NotchConfig) {
        for (name, values) in other.sections {
            sections[name, default: [:]].merge(values) { _, new in new }
        }
    }

    /// The `[connectors.<id>]` table.
    public func connector(_ id: String) -> ConfigSection { self["connectors.\(id)"] }

    // MARK: Loading

    public static var defaultURL: URL { Brand.supportFolder.appending(path: "config.toml") }

    /// The file's config, or an empty one when it's missing or broken (the error is returned for
    /// the log; the app keeps running on defaults).
    public static func load(from url: URL = defaultURL) -> (config: NotchConfig, error: ParseError?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (NotchConfig(), nil) }
        do { return (try parse(text), nil) } catch let error as ParseError { return (NotchConfig(), error) } catch {
            return (NotchConfig(), ParseError(line: 0, message: "\(error)"))
        }
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> NotchConfig {
        var config = NotchConfig()
        var section = ""
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw ParseError(line: number, message: "expected [section]")
                }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !section.isEmpty, section.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
                    throw ParseError(line: number, message: "bad section name")
                }
                if config.sections[section] == nil { config.sections[section] = [:] }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw ParseError(line: number, message: "expected key = value") }
            var key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { key = String(key.dropFirst().dropLast()) }
            guard !key.isEmpty else { throw ParseError(line: number, message: "empty key") }
            let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            var scanner = ValueScanner(text: Array(rest))
            guard let value = scanner.value(), scanner.atEnd else {
                throw ParseError(line: number, message: "can't read the value of \(key)")
            }
            config.sections[section, default: [:]][key] = value
        }
        return config
    }

    /// Drops a `#` comment that isn't inside a string.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if escaped { escaped = false; continue }
                if character == "\\" && open == "\"" { escaped = true; continue }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    private struct ValueScanner {
        let text: [Character]
        var position = 0

        var atEnd: Bool {
            var index = position
            while index < text.count, text[index] == " " || text[index] == "\t" { index += 1 }
            return index == text.count
        }

        mutating func skipSpaces() {
            while position < text.count, text[position] == " " || text[position] == "\t" { position += 1 }
        }

        mutating func value() -> ConfigValue? {
            skipSpaces()
            guard position < text.count else { return nil }
            switch text[position] {
            case "\"": return basicString().map(ConfigValue.string)
            case "'": return literalString().map(ConfigValue.string)
            case "[": return array()
            default: return bare()
            }
        }

        mutating func basicString() -> String? {
            position += 1
            var result = ""
            while position < text.count {
                let character = text[position]
                position += 1
                if character == "\"" { return result }
                if character == "\\" {
                    guard position < text.count else { return nil }
                    let next = text[position]
                    position += 1
                    switch next {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    default: return nil
                    }
                } else {
                    result.append(character)
                }
            }
            return nil
        }

        mutating func literalString() -> String? {
            position += 1
            var result = ""
            while position < text.count {
                let character = text[position]
                position += 1
                if character == "'" { return result }
                result.append(character)
            }
            return nil
        }

        mutating func array() -> ConfigValue? {
            position += 1
            var items: [ConfigValue] = []
            while true {
                skipSpaces()
                guard position < text.count else { return nil }
                if text[position] == "]" { position += 1; return .array(items) }
                guard let item = value() else { return nil }
                items.append(item)
                skipSpaces()
                guard position < text.count else { return nil }
                if text[position] == "," { position += 1; continue }
                if text[position] == "]" { position += 1; return .array(items) }
                return nil
            }
        }

        mutating func bare() -> ConfigValue? {
            var token = ""
            while position < text.count, !",] \t".contains(text[position]) {
                token.append(text[position])
                position += 1
            }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                let clean = token.replacingOccurrences(of: "_", with: "")
                if let int = Int(clean) { return .int(int) }
                if let double = Double(clean) { return .double(double) }
                return nil
            }
        }
    }
}

/// One table of the config with typed lookups and defaults.
public struct ConfigSection: Equatable, Sendable {
    public var name: String
    public var values: [String: ConfigValue]

    public init(name: String = "", values: [String: ConfigValue] = [:]) {
        self.name = name
        self.values = values
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { return value }
        return nil
    }

    public func string(_ key: String, default fallback: String) -> String { string(key) ?? fallback }

    public func bool(_ key: String, default fallback: Bool) -> Bool {
        if case .bool(let value)? = values[key] { return value }
        return fallback
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        if case .int(let value)? = values[key] { return value }
        return fallback
    }

    public func strings(_ key: String) -> [String]? {
        guard case .array(let items)? = values[key] else { return nil }
        return items.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }

    /// A path with `~` expanded; `nil` when missing or empty.
    public func path(_ key: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let raw = string(key)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home.appending(path: String(raw.dropFirst(2))) }
        return URL(fileURLWithPath: raw)
    }

    public func url(_ key: String) -> URL? {
        string(key).flatMap { URL(string: $0) }.flatMap { $0.scheme == nil ? nil : $0 }
    }
}
