import Foundation

/// Which project a session belongs to: the repo folder, also from inside a worktree.
public enum ProjectKey {
    public static func project(cwd: String) -> String {
        var path = cwd
        while path.hasSuffix("/") { path.removeLast() }
        // Worktrees of Claude Code and git: <repo>/.claude/worktrees/<name>, <repo>/.worktrees/<name>.
        for marker in ["/.claude/worktrees/", "/.worktrees/", "/worktrees/"] {
            if let range = path.range(of: marker) { path = String(path[..<range.lowerBound]) }
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// The user's choice for a project: its character and base colour (a hue shift).
public struct ProjectStyle: Codable, Equatable, Sendable {
    public var character: String?
    public var hue: Double

    public init(character: String? = nil, hue: Double = 0) {
        self.character = character
        self.hue = hue
    }
}

public enum ProjectAssignment {
    /// The project's character: the user's pick, a configured default (`[characters] projects`
    /// in config.toml), or a stable one from the cast.
    public static func character(project: String, styles: [String: ProjectStyle], characters: [String],
                                 defaults: [String: String] = [:], fallback: String? = nil) -> String {
        if let picked = styles[project]?.character, characters.contains(picked) { return picked }
        if let fixed = defaults[project], characters.contains(fixed) { return fixed }
        if let fallback, characters.contains(fallback) { return fallback }
        let pool = characters.filter { !defaults.values.contains($0) }.sorted()
        guard !pool.isEmpty else { return characters.first ?? "" }
        var hash: UInt64 = 5381
        for byte in project.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return pool[Int(hash % UInt64(pool.count))]
    }

    /// Characters for many projects at once without two sharing one (while the cast lasts):
    /// picks and defaults first, then each project's hashed choice, moving on when it's taken.
    /// Stable as long as the set of projects is.
    /// With a `fallback` character, every project without a pick or default gets that one (they
    /// differ by colour); without, each gets its own.
    public static func characters(projects: [String], styles: [String: ProjectStyle], characters: [String],
                                  defaults: [String: String] = [:], fallback: String? = nil) -> [String: String] {
        var result: [String: String] = [:]
        var taken = Set<String>()
        for project in projects {
            if let picked = styles[project]?.character, characters.contains(picked) { result[project] = picked }
            else if let fixed = defaults[project], characters.contains(fixed) { result[project] = fixed }
            if let chosen = result[project] { taken.insert(chosen) }
        }
        if let fallback, characters.contains(fallback) {
            for project in projects where result[project] == nil { result[project] = fallback }
            return result
        }
        let pool = characters.filter { !defaults.values.contains($0) }.sorted()
        guard !pool.isEmpty else { return result }
        for project in projects.sorted() where result[project] == nil {
            var hash: UInt64 = 5381
            for byte in project.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
            let start = Int(hash % UInt64(pool.count))
            let free = (0..<pool.count).map { pool[(start + $0) % pool.count] }.first { !taken.contains($0) }
            let chosen = free ?? pool[start]
            result[project] = chosen
            taken.insert(chosen)
        }
        return result
    }
}

/// How hard a session runs, from the transcript's `effort` field (latest assistant message).
public enum PerformanceLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh, max, ultra

    public init?(effort: String) {
        switch effort.lowercased() {
        case "low", "minimal": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh", "extra-high", "extra_high": self = .xhigh
        case "max", "maximum": self = .max
        case "ultra", "ultra-code", "ultracode": self = .ultra
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }

    /// Colorway per level until the user changes it: light to dark as the effort rises.
    public static let defaultScale: [PerformanceLevel: String] = [
        .low: "white", .medium: "mint", .high: "sky_blue", .xhigh: "indigo_glow", .max: "matte_black",
        .ultra: "matte_black",
    ]
}

public enum ColourBy: String, Codable, Sendable { case performance, session }

public enum SessionColours {
    public struct Session: Sendable {
        public var id: String
        public var level: PerformanceLevel?
        public var started: Date?

        public init(id: String, level: PerformanceLevel?, started: Date?) {
            self.id = id
            self.level = level
            self.started = started
        }
    }

    /// Colorway and a small extra hue for each session of one project.
    /// - Performance: the level's colorway; sessions sharing a level get +12°, +24° … so they stay
    ///   apart. Sessions without a known level use the session order.
    /// - Session: one colorway per session in start order.
    public static func assign(_ sessions: [Session],
                              by mode: ColourBy, scale: [PerformanceLevel: String],
                              sessionPalette: [String]) -> [String: (colorway: String, offset: Double)] {
        let ordered = sessions.sorted { ($0.started ?? .distantPast, $0.id) < ($1.started ?? .distantPast, $1.id) }
        var result: [String: (String, Double)] = [:]
        var seen: [String: Int] = [:]
        for (index, session) in ordered.enumerated() {
            let colorway: String
            if mode == .performance, let level = session.level {
                colorway = scale[level] ?? PerformanceLevel.defaultScale[level]!
            } else {
                colorway = sessionPalette.isEmpty ? "lavender" : sessionPalette[index % sessionPalette.count]
            }
            let count = seen[colorway, default: 0]
            seen[colorway] = count + 1
            result[session.id] = (colorway, Double(count) * 12)
        }
        return result
    }
}

/// What a character shows for a session: whether colour may be applied to it, and which effort
/// level's own look (if any). Characters that aren't tintable (the cat: its body keeps its
/// natural colours, only the eyes follow the effort) never get hue shifts, session colours or
/// colour-scale picks; their level look always follows the session's effort.
public enum LookPolicy {
    public struct Look: Equatable, Sendable {
        /// Colour (a colorway, a hue offset) may be applied to the sprites.
        public var tinted: Bool
        /// The level whose own look to draw, if any.
        public var level: PerformanceLevel?

        public init(tinted: Bool, level: PerformanceLevel?) {
            self.tinted = tinted
            self.level = level
        }
    }

    /// - Parameters:
    ///   - customized: the user picked a colour for this level in Settings.
    ///   - levelLooks: levels the character has its own look for.
    public static func look(tintable: Bool, colourBy: ColourBy, level: PerformanceLevel?, customized: Bool,
                            levelLooks: Set<PerformanceLevel>) -> Look {
        guard let level, levelLooks.contains(level) else { return Look(tinted: tintable, level: nil) }
        if !tintable { return Look(tinted: false, level: level) }
        return Look(tinted: true, level: colourBy == .performance && !customized ? level : nil)
    }
}
