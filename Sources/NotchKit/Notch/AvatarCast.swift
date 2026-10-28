import AppKit
import NotchCore
import Observation
import SwiftUI

/// Characters from `.notchpack` folders: the packs in the app bundle (`Resources/Characters`)
/// first, then the user's in `~/Library/Application Support/<App>/Characters`. A pack is a folder
/// with `manifest.json` and its sprites (see docs/CHARACTER_PACKS.md). The first character of the
/// first pack leads unless `[characters] main` in config.toml names another.
final class AvatarLibrary: @unchecked Sendable {
    struct Sprite: Decodable {
        var file: String
        /// Figure height in the source image; small crops look soft when drawn big.
        var sourceHeight: Int
        /// The pack folder the file is relative to (set after loading).
        var root: URL?

        enum CodingKeys: String, CodingKey { case file, sourceHeight }
    }

    struct Character: Decodable {
        var id: String
        var name: String
        var portrait: Sprite?
        var states: [String: Sprite]
        var colorways: [String: Sprite]
        var colorwayNames: [String: String]
        var tint: String
        /// Per effort level (`low` … `ultra`): states that replace the base ones and/or a colorway.
        var levels: [String: LevelVariant]
        /// How the app finishes the sprites: a soft outer glow in the colour's tint, a top sheen.
        var finish: Finish?
        /// `false`: the app never recolours this character (no colorways, hue offsets or session
        /// colours); its levels change other things, like the cat's eyes.
        var tintable: Bool

        struct Finish: Decodable {
            /// Glow opacity, 0 to 1.
            var glow: Double?
            /// Sheen strength on the upper half, 0 to 1.
            var highlight: Double?
        }
        /// The pack it came from.
        var pack: String = ""

        /// A character's look at one effort level.
        struct LevelVariant: Decodable {
            /// Name shown in Settings, e.g. "Mint".
            var name: String?
            /// Colorway key (built in or from the pack's `recipes`); none = the sprites' own colours.
            var colorway: String?
            /// Sprites that replace base states at this level (e.g. other eyes while working).
            var states: [String: Sprite]?
            /// "#RRGGBB" of this look, for the glow and accents.
            var tint: String?
        }

        enum CodingKeys: String, CodingKey { case id, name, portrait, states, colorways, colorwayNames, tint, levels, finish, tintable }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            portrait = try c.decodeIfPresent(Sprite.self, forKey: .portrait)
            states = try c.decodeIfPresent([String: Sprite].self, forKey: .states) ?? [:]
            colorways = try c.decodeIfPresent([String: Sprite].self, forKey: .colorways) ?? [:]
            colorwayNames = try c.decodeIfPresent([String: String].self, forKey: .colorwayNames) ?? [:]
            tint = try c.decodeIfPresent(String.self, forKey: .tint) ?? "#4C8DFF"
            levels = try c.decodeIfPresent([String: LevelVariant].self, forKey: .levels) ?? [:]
            finish = try c.decodeIfPresent(Finish.self, forKey: .finish)
            tintable = try c.decodeIfPresent(Bool.self, forKey: .tintable) ?? true
        }

        /// Points every sprite at the pack folder.
        mutating func resolve(in root: URL, pack: String) {
            self.pack = pack
            portrait?.root = root
            states = states.mapValues { var sprite = $0; sprite.root = root; return sprite }
            colorways = colorways.mapValues { var sprite = $0; sprite.root = root; return sprite }
            levels = levels.mapValues { variant in
                var variant = variant
                variant.states = variant.states?.mapValues { var sprite = $0; sprite.root = root; return sprite }
                return variant
            }
        }

        func variant(_ level: PerformanceLevel?) -> LevelVariant? { level.flatMap { levels[$0.rawValue] } }

        /// Levels with their own look.
        var levelLooks: Set<PerformanceLevel> { Set(levels.keys.compactMap(PerformanceLevel.init(rawValue:))) }
    }

    /// A colorway a pack defines (`recipes` in manifest.json), offered in Settings like the built-in ones.
    struct Recipe: Decodable {
        var key: String
        var name: String
        var hue: Double?
        var saturation: Double?
        var brightness: Double?
        var contrast: Double?
        var shade: Double?
        /// "#RRGGBB" and how strongly (0 to 1).
        var tint: String?
        var tintAmount: Double?

        var colorway: Colorway {
            Colorway(hue: hue ?? 0, saturation: saturation ?? 1, brightness: brightness ?? 0,
                     contrast: contrast ?? 1, shade: shade ?? 1,
                     tint: tint.flatMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) },
                     tintAmount: tintAmount ?? (tint == nil ? 0 : 0.8))
        }
    }

    /// `manifest.json` of a pack.
    struct Manifest: Decodable {
        var format: Int?
        var id: String
        var name: String?
        var version: String?
        var license: String?
        var recipes: [Recipe]?
        var characters: [Character]
    }

    static let shared = AvatarLibrary()

    let characters: [Character]
    /// Loaded packs: id and name, for Settings.
    let packs: [(id: String, name: String)]
    /// Colorways the packs define.
    let recipes: [Recipe]
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    static var userFolder: URL { Brand.supportFolder.appending(path: "Characters") }

    static var searchFolders: [URL] {
        [
            Bundle.main.resourceURL?.appending(path: "Characters"),
            // `swift run` from the repo.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Characters"),
            userFolder,
        ].compactMap { $0 }
    }

    init(folders: [URL] = AvatarLibrary.searchFolders, main: String? = Runtime.mainCharacter,
         only allowed: [String]? = Runtime.characterPacks) {
        let fm = FileManager.default
        var characters: [Character] = []
        var packs: [(String, String)] = []
        var recipes: [Recipe] = []
        var seenFolders = Set<String>()
        for folder in folders {
            let resolved = folder.resolvingSymlinksInPath().path
            guard seenFolders.insert(resolved).inserted else { continue }
            let entries = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "notchpack" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for pack in entries {
                guard let data = try? Data(contentsOf: pack.appending(path: "manifest.json")) else { continue }
                do {
                    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                    guard !packs.contains(where: { $0.0 == manifest.id }),
                          allowed?.contains(manifest.id) ?? true else { continue }
                    packs.append((manifest.id, manifest.name ?? manifest.id))
                    for recipe in manifest.recipes ?? [] where !recipes.contains(where: { $0.key == recipe.key }) {
                        recipes.append(recipe)
                    }
                    for var character in manifest.characters where !characters.contains(where: { $0.id == character.id }) {
                        character.resolve(in: pack, pack: manifest.id)
                        characters.append(character)
                    }
                } catch {
                    Log.app.error("Character pack \(pack.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // The configured main character first, then pack order.
        if let main, let index = characters.firstIndex(where: { $0.id == main }) {
            characters.insert(characters.remove(at: index), at: 0)
        }
        self.characters = characters
        self.packs = packs
        self.recipes = recipes
        if characters.isEmpty { Log.app.error("No character packs found") }
    }

    var ids: [String] { characters.map(\.id) }

    func character(_ id: String) -> Character? { characters.first { $0.id == id } }

    func image(_ sprite: Sprite) -> NSImage? {
        guard let root = sprite.root else { return nil }
        let url = root.appending(path: sprite.file)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url.path] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = image
        return image
    }

    /// Width over height of a sprite.
    func aspect(_ sprite: Sprite) -> CGFloat {
        guard let image = image(sprite), image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    func tint(_ id: String) -> Color {
        guard let hex = character(id)?.tint.dropFirst(), let value = UInt32(hex, radix: 16) else { return Theme.accent }
        return Color(hex: value)
    }
}

/// A colour variant of a character: a hue shift plus saturation and brightness of its sprites.
struct Colorway: Equatable {
    var hue: Double = 0
    var saturation: Double = 1
    var brightness: Double = 0
    var contrast: Double = 1
    /// Multiplies the colours in linear light (1 = unchanged); 0.1 turns white into dark slate, black stays black.
    var shade: Double = 1
    /// Washes the sprite in one colour (0xRRGGBB), keeping its light and shadow; for figures
    /// whose own colours are a gradient that a hue shift would turn into a rainbow.
    var tint: UInt32? = nil
    var tintAmount: Double = 0

    var isIdentity: Bool {
        hue == 0 && saturation == 1 && brightness == 0 && contrast == 1 && shade == 1 && (tint == nil || tintAmount == 0)
    }
    /// Dark enough to sink into the black card: such figures get a rim light.
    var isDark: Bool { shade < 0.5 || brightness < -0.3 }

    func shifted(by degrees: Double) -> Colorway {
        var copy = self
        copy.hue += degrees
        return copy
    }

    /// Colorways as recipes on the base sprites, so every pose keeps working: each turns a
    /// character's own colours the same way; white and black work for all.
    /// Built-in colorways plus those the character packs define.
    static var recipes: [(key: String, name: String, colorway: Colorway)] {
        builtIn + AvatarLibrary.shared.recipes.filter { recipe in !builtIn.contains { $0.key == recipe.key } }
            .map { ($0.key, $0.name, $0.colorway) }
    }

    static let builtIn: [(key: String, name: String, colorway: Colorway)] = [
        ("lavender", "Lavender", Colorway()),
        ("white", "White", Colorway(saturation: 0.12, brightness: 0.12)),
        ("mint", "Mint", Colorway(hue: -112, saturation: 0.9)),
        ("sky_blue", "Sky Blue", Colorway(hue: -45, saturation: 1.1)),
        ("indigo_glow", "Indigo Glow", Colorway(hue: -22, saturation: 1.7, brightness: -0.18)),
        ("blush_pink", "Blush Pink", Colorway(hue: 95, saturation: 0.95)),
        ("chrome", "Chrome", Colorway(saturation: 0, brightness: 0.04)),
        // A dark slate; the rim light keeps the silhouette readable, the eyes stay visible.
        ("matte_black", "Matte Black", Colorway(saturation: 0.35, contrast: 1.1, shade: 0.1)),
    ]

    static func named(_ key: String) -> Colorway { recipes.first { $0.key == key }?.colorway ?? Colorway() }
    static func title(_ key: String) -> String { recipes.first { $0.key == key }?.name ?? key }
}

/// Who plays whom: one character per project (config.toml can fix some, the user picks in
/// Settings), sessions of a project in colour variants.
@MainActor
@Observable
final class AvatarCast {
    let library = AvatarLibrary.shared
    @ObservationIgnored private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    /// The home project (`[characters] home_project`); its character stands in where no session
    /// is involved (music, dictation, capture, empty states). Without one, the lead character.
    static var homeProject: String { Runtime.homeProject }

    var main: String {
        Self.homeProject.isEmpty ? (picked ?? library.characters.first?.id ?? "") : character(forProject: Self.homeProject)
    }
    /// The home character outside sessions (music, dictation, capture): the colour picked in
    /// onboarding or Settings, else its base look.
    var colorway: Colorway { state.settings.colorway.map(Colorway.named) ?? Colorway() }

    /// The main character picked in onboarding or Settings, while its pack is installed.
    private var picked: String? {
        let id = state.settings.mainCharacter
        return library.character(id) == nil ? nil : id
    }

    /// Picks the main character; with a home project, that project's character too.
    func setMain(_ id: String) {
        state.settings.mainCharacter = id
        if !Self.homeProject.isEmpty { setStyle(project: Self.homeProject, character: id) }
    }

    func setMainColorway(_ key: String?) { state.settings.colorway = key }

    var colourBy: ColourBy { state.settings.colourBy }
    var colourScale: [PerformanceLevel: String] { state.settings.colourScale }

    func setColour(_ key: String, for level: PerformanceLevel) { state.settings.colourScale[level] = key }

    /// The user picked a colour for this level (anything but the default scale's).
    func isCustomized(_ level: PerformanceLevel) -> Bool {
        (colourScale[level] ?? PerformanceLevel.defaultScale[level]) != PerformanceLevel.defaultScale[level]
    }

    func isTintable(_ character: String) -> Bool { library.character(character)?.tintable ?? true }

    /// What a session of this character shows (see `LookPolicy`).
    func look(of character: String, level: PerformanceLevel?) -> LookPolicy.Look {
        guard let info = library.character(character) else { return LookPolicy.Look(tinted: true, level: nil) }
        return LookPolicy.look(tintable: info.tintable, colourBy: colourBy, level: level,
                               customized: level.map(isCustomized) ?? false, levelLooks: info.levelLooks)
    }

    /// A character's own look for a level, from its pack.
    func variant(of character: String, level: PerformanceLevel) -> AvatarLibrary.Character.LevelVariant? {
        library.character(character)?.variant(level)
    }
    func setColourBy(_ mode: ColourBy) { state.settings.colourBy = mode }

    /// Projects seen so far (Settings list and live sessions); characters are spread over them.
    var projects: Set<String> = AvatarCast.homeProject.isEmpty ? [] : [AvatarCast.homeProject]

    func register(_ names: some Sequence<String>) {
        let new = projects.union(names)
        if new != projects { projects = new }
    }

    /// Previews: one character for every project, without touching the saved picks.
    var previewCharacter: String?

    func character(forProject project: String) -> String {
        if let previewCharacter { return previewCharacter }
        let all = projects.union([project])
        let defaults = Runtime.projectCharacters
        // Projects without a pick follow the main character when config.toml names no fallback.
        let fallback = Runtime.fallbackCharacter.map { $0 == library.characters.first?.id ? (picked ?? $0) : $0 }
        return ProjectAssignment.characters(projects: Array(all), styles: state.settings.projects, characters: library.ids,
                                            defaults: defaults, fallback: fallback)[project]
            ?? ProjectAssignment.character(project: project, styles: state.settings.projects, characters: library.ids,
                                           defaults: defaults, fallback: fallback)
    }

    func setStyle(project: String, character: String? = nil, hue: Double? = nil) {
        var style = state.settings.projects[project] ?? ProjectStyle()
        if let character { style.character = character }
        if let hue { style.hue = hue }
        state.settings.projects[project] = style
    }
}

/// A character in a mood, drawn so that its bottom edge sits on the edge it leans on.
/// `emerged` drives a small entrance: closed, peek, pop up, look around,
/// react; and slowly hide when it goes false. With Reduce Motion it only fades.
struct AvatarView: View {
    let character: String
    let mood: AvatarMood
    var height: CGFloat
    var colorway = Colorway()
    /// 0 = fully out, 1 = hidden below its edge. Compact peeks at about 0.3.
    var sink: CGFloat = 0
    var emerged = true
    /// Play the emerge sequence when it appears; off when the figure only moves between places.
    var emergeOnAppear = true
    /// Idle life (breathing, blinks, hops by mood); off for still pictures like Settings tiles.
    var alive = true
    /// The session's effort level when colours follow performance: a character may bring its own
    /// sprites for it (the cat's eyes).
    var level: PerformanceLevel?
    /// Previews: draw this state, whatever the mood.
    var forcedState: String?

    @State private var phase: CGFloat
    @State private var tilt: Double = 0

    init(character: String, mood: AvatarMood, height: CGFloat, colorway: Colorway = Colorway(),
         sink: CGFloat = 0, emerged: Bool = true, emergeOnAppear: Bool = true, alive: Bool = true,
         level: PerformanceLevel? = nil, forcedState: String? = nil) {
        self.level = level
        self.forcedState = forcedState
        self.character = character
        self.mood = mood
        self.height = height
        self.colorway = colorway
        self.sink = sink
        self.emerged = emerged
        self.emergeOnAppear = emergeOnAppear
        self.alive = alive
        // Hidden only when it will rise; figures that just move between places start out.
        _phase = State(initialValue: emerged && emergeOnAppear ? 1 : 0)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.figuresHidden) private var figuresHidden

    private let library = AvatarLibrary.shared

    var body: some View {
        if figuresHidden {
            // Watch mode: no figure, and no width, so rows and ears close up around the text.
            Color.clear.frame(width: 0, height: height)
        } else {
            figure
        }
    }

    private var figure: some View {
        let picked = sprite
        return ZStack(alignment: .bottom) {
            if let image = picked.flatMap(library.image) {
                // Characters that aren't tintable keep their own colours, whatever the caller asks.
                let colorway = library.character(character)?.tintable == false ? Colorway() : colorway
                SpriteLayerView(image: image, colorway: colorway, mood: mood, alive: alive,
                                glow: glow, highlight: library.character(character)?.finish?.highlight ?? 0)
                    .aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit)
                    .overlay { if drawsHeadphones { Headphones() } }
                    .frame(height: height, alignment: .bottom)
                    // One view for every state: the sprite layer cross-fades between pictures.
            }
        }
        .frame(height: height, alignment: .bottom)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        // Leans and bobs on hover and when the peek opens (still pictures stay still).
        .modifier(FigureNudge(enabled: alive && forcedState == nil))
        .offset(y: height * max(sink, reduceMotion ? 0 : phase))
        .opacity(reduceMotion ? (emerged ? 1 : 0) : 1)
        .animation(.spring(duration: 0.45, bounce: 0.25), value: sink)
        .task {
            if emerged && emergeOnAppear { await emerge() } else if emerged { phase = 0 }
        }
        .onChange(of: emerged) { _, now in
            if now { Task { await emerge() } } else { hide() }
        }
        .accessibilityHidden(true)
    }

    /// The pose for the mood. Wide use-case poses (laptop, arms spread) are skipped: they
    /// shrink to a sliver in the ears and chips; the upright expressions read at every size.
    /// Falls back to the portrait when the character has no states or the crop is far too
    /// small for this size (sprites are drawn at 2x).
    private var sprite: AvatarLibrary.Sprite? {
        guard let character = library.character(character) else { return nil }
        if let forcedState { return character.variant(level)?.states?[forcedState] ?? character.states[forcedState] }
        // Level sprites win for the moods they cover; they may be wider (a peek over the edge).
        if let states = character.variant(level)?.states,
           let state = AvatarStates.candidates[mood]?.first(where: { states[$0] != nil }) {
            return states[state]
        }
        let upright = Set(character.states.compactMap { state, sprite in
            library.aspect(sprite) <= Self.maxAspect ? state : nil
        })
        let available = upright.isEmpty ? Set(character.states.keys) : upright
        if let state = AvatarStates.state(for: mood, available: available),
           let sprite = character.states[state],
           CGFloat(sprite.sourceHeight) >= height * 0.5 || character.portrait == nil {
            return sprite
        }
        return character.portrait ?? character.states.values.first
    }

    static let maxAspect: CGFloat = 1.6

    /// Listening or music, and the pack maps its listening states to a plain face (the bundled
    /// star has no headphones picture): the headphones are drawn on. Characters with their own
    /// listening pictures, and those without any listening state, are left alone.
    private var drawsHeadphones: Bool {
        guard mood == .music || mood == .listening, forcedState == nil, let character = library.character(character) else { return false }
        let listening = ["voice_listening", "music_playback", "music"].compactMap { character.states[$0]?.file }
        let plain = Set(["happy", "idle"].compactMap { character.states[$0]?.file })
        return !listening.isEmpty && listening.allSatisfy(plain.contains)
    }

    /// The pack's glow in the look's colour: the level's tint, else the colorway's, else the character's.
    private var glow: (color: CGColor, amount: Double)? {
        guard let character = library.character(character), let amount = character.finish?.glow, amount > 0 else { return nil }
        let hex = character.variant(level)?.tint ?? character.tint
        var value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x7A6CFF
        if let tint = colorway.tint, colorway.tintAmount > 0.4 { value = tint }
        let color = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        return (color.cgColor, amount)
    }

    @MainActor private func emerge() async {
        guard !reduceMotion else {
            phase = 0
            return
        }
        do {
            phase = 1
            withAnimation(.easeOut(duration: 0.18)) { phase = 0.55 }       // peek
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(duration: 0.42, bounce: 0.38)) { phase = 0 }  // pop up
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeInOut(duration: 0.28)) { tilt = -5 }        // look around
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeInOut(duration: 0.34)) { tilt = 4 }
            try? await Task.sleep(for: .milliseconds(340))
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { tilt = 0 }
        }
        // Interrupted (view went away mid-sequence): never leave it half sunk.
        if phase != 0 { phase = 0 }
    }

    private func hide() {
        guard !reduceMotion else { return }
        withAnimation(.easeIn(duration: 0.55)) { phase = 1 }                // slowly hide
    }
}

/// Headphones over the star's face: a band over the top of the face and a cup at each side, in
/// the figure's own proportions, so they move, tilt and squash with it.
private struct Headphones: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let line = max(1, h * 0.045)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: w * 0.31, y: h * 0.53))
                    path.addCurve(to: CGPoint(x: w * 0.69, y: h * 0.53),
                                  control1: CGPoint(x: w * 0.31, y: h * 0.30),
                                  control2: CGPoint(x: w * 0.69, y: h * 0.30))
                }
                .stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: line, lineCap: .round))
                ForEach([0.30, 0.70], id: \.self) { x in
                    RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                        .fill(Color(white: 0.93))
                        .frame(width: w * 0.085, height: h * 0.16)
                        .shadow(color: .black.opacity(0.35), radius: line)
                        .position(x: w * x, y: h * 0.57)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

