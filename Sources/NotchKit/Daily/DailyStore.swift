import AppKit
import CoreLocation
import NotchCore
import Observation
import SwiftUI

/// The daily tools' state: weather (Open-Meteo), the work day, notes and sleep and recovery from a
/// wearable. Nothing runs and nothing goes over the network while a tool is off. One store for
/// the app: the calendar header, the ears, the Tools tab and Settings all read it.
@MainActor
@Observable
final class DailyStore {
    static let shared = DailyStore()

    var settings: DailySettings {
        didSet {
            guard settings != oldValue else { return }
            if persists, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
            if settings.place != oldValue.place || settings.unit != oldValue.unit {
                weather = nil
                refreshWeather(force: true)
            }
            if settings.healthSource != oldValue.healthSource {
                health = nil
                refreshHealth(force: true)
            }
            if settings.notesFolder != oldValue.notesFolder { notes.folder = notesFolder }
        }
    }

    enum WeatherStatus: Equatable {
        case idle, loading, ok
        /// Waiting for macOS to say where the Mac is.
        case locating
        /// Location is off for the app and no city is set.
        case needsPlace
        case offline
    }

    enum HealthStatus: Equatable {
        case idle, loading, ok
        /// No token yet, or WHOOP not connected.
        case needsSetup
        case failed(String)
    }

    private(set) var weather: WeatherReport?
    private(set) var weatherStatus = WeatherStatus.idle
    private(set) var health: HealthDay?
    /// Location for the app, kept current: CoreLocation says when it changes in System Settings.
    private(set) var locationStatus = CLAuthorizationStatus.notDetermined
    private(set) var healthStatus = HealthStatus.idle
    /// The calendar shows Today (the day card) instead of the agenda.
    var cardShown = true
    /// The calendar tab opens on Today, unless a meeting is close (off for the calendar's previews).
    @ObservationIgnored var opensOnToday = true
    /// Today's to-dos (set by the app): the Today module's tasks and reminders.
    @ObservationIgnored weak var today: TodayModule?
    /// Apple Reminders are switched on and allowed (kept current by the app).
    var remindersShown = false
    /// Switches Apple Reminders on: macOS asks for access on this click, never before.
    @ObservationIgnored var turnOnReminders: (() -> Void)?
    /// Opens the settings for a place or a wearable.
    @ObservationIgnored var openSettings: (() -> Void)?
    /// The minute on the clock, while a tool needs it (day progress follows it).
    private(set) var now = Date()
    let notes = NotesStore()

    /// The daily tools switched on (from the Tools gallery).
    private(set) var on: Set<ToolFeature> = []
    /// Previews change nothing on disk and fetch nothing.
    @ObservationIgnored var persists = true
    @ObservationIgnored private var preview = false
    /// A preview shows these tools whatever the switches say.
    @ObservationIgnored private var previewFeatures: Set<ToolFeature>?
    /// Once a morning: last night's scores and today's weather. Returns whether the line got
    /// through (it doesn't while the panel is open or in Watch mode); if not, it comes again.
    @ObservationIgnored var onMorningLine: ((HealthDay, WeatherReport?) -> Bool)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    /// Each request counts up; an answer for an older one (another city, unit or source) is dropped.
    @ObservationIgnored private var weatherGeneration = 0
    @ObservationIgnored private var healthGeneration = 0
    @ObservationIgnored private let locator = Locator()
    /// A sign-in in the browser, waiting for its answer.
    @ObservationIgnored private var login: (source: HealthSource, verifier: String, state: String)?
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static let settingsKey = "dailySettings"
    private static let locationKey = "daily.location"
    private static let morningKey = "daily.morningShown"

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DailySettings.self, from: $0) }
        settings = stored ?? DailySettings(unit: DailySettings.defaultUnit(for: .current))
        weather = Self.readCache(WeatherReport.self, "weather.json")
        health = Self.readCache(HealthDay.self, "health.json")
        notes.folder = notesFolder
        locationStatus = locator.status
        locator.onStatusChange = { [weak self] status in self?.locationChanged(status) }
        // Back from System Settings: read again, CoreLocation may not have said yet.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.locationChanged($0.locator.status) } }
        }
    }

    func isOn(_ feature: ToolFeature) -> Bool { on.contains(feature) }

    var notesFolder: URL {
        settings.notesFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? Brand.supportFolder.appending(path: "notes", directoryHint: .isDirectory)
    }

    // MARK: Switching

    /// The tools switched on in the gallery; starts what they need, stops the rest.
    func apply(on features: Set<ToolFeature>) {
        let daily: Set<ToolFeature> = [.weather, .dayProgress, .notes, .health]
        let next = (previewFeatures ?? features).intersection(daily)
        guard next != on || loop == nil else { return }
        let added = next.subtracting(on)
        on = next
        guard !preview else { return }
        if added.contains(.weather) { refreshWeather() }
        if added.contains(.health) {
            connected = Set(HealthSource.allCases.filter { Keychain.codable(WhoopAPI.Token.self, Self.tokenItem($0)) != nil })
            refreshHealth()
        }
        if added.contains(.notes) { notes.load() }
        if on.isDisjoint(with: [.weather, .health, .dayProgress]) { stopLoop() } else { startLoop() }
    }

    /// Every minute while weather, day progress or health is on: the clock, what is stale, the
    /// morning line. Also on wake and when the screen is unlocked: the user is back.
    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        observers = events.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    private func tick() {
        let now = Date()
        self.now = now
        if isOn(.weather), weather.map({ !$0.isFresh(at: now) }) ?? true { refreshWeather() }
        // Sleep is scored once a night: hourly is plenty, more often while today's scores are missing.
        if isOn(.health), health.map({ now.timeIntervalSince($0.fetched) > ($0.day == MorningLine.day(now) ? 3600 : 900) }) ?? true {
            refreshHealth()
        }
        checkMorningLine(now: now)
    }

    // MARK: Weather

    /// The weather to show: fresh enough, in the unit set and for the place set.
    var shownWeather: WeatherReport? {
        guard let weather, weather.isUsable(at: Date()), weather.unit == settings.unit, weather.matches(settings.place) else { return nil }
        return weather
    }

    /// `force` (a new city or unit) starts over even while a request runs; its answer is dropped.
    func refreshWeather(force: Bool = false, askLocation: Bool = false) {
        guard isOn(.weather), !preview, force || weatherTask == nil else { return }
        if !force, let weather = shownWeather, weather.isFresh(at: Date()) { return }
        weatherTask?.cancel()
        weatherGeneration += 1
        let generation = weatherGeneration
        weatherTask = Task { [weak self] in
            await self?.loadWeather(generation, askLocation: askLocation)
            if self?.weatherGeneration == generation { self?.weatherTask = nil }
        }
    }

    private func loadWeather(_ generation: Int, askLocation: Bool) async {
        // What this request is for, read once: the settings may change while it waits.
        let unit = settings.unit, chosen = settings.place
        weatherStatus = shownWeather == nil ? .loading : weatherStatus
        let place: GeoPlace
        if let chosen {
            place = chosen
        } else {
            weatherStatus = shownWeather == nil ? .locating : weatherStatus
            let found = await locate(ask: askLocation)
            guard generation == weatherGeneration else { return }
            guard let found else {
                weatherStatus = .needsPlace
                return
            }
            place = found
        }
        let url = OpenMeteo.forecastURL(latitude: place.latitude, longitude: place.longitude, unit: unit, apiKey: Self.weatherKey)
        do {
            let data = try await Self.fetch(URLRequest(url: url))
            guard generation == weatherGeneration else { return }
            let report = try OpenMeteo.parseForecast(data, unit: unit, fetched: Date(), place: place, located: chosen == nil)
            withAnimation(Theme.snappy) { weather = report }
            weatherStatus = .ok
            Self.writeCache(report, "weather.json")
        } catch {
            guard generation == weatherGeneration else { return }
            // Offline: the last forecast stays while it is usable.
            weatherStatus = .offline
            Log.app.info("Weather: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A key for Open-Meteo's customer API (`[weather] api_key` in config.toml); without one the
    /// free API answers, which Open-Meteo allows for non-commercial use.
    private static var weatherKey: String? { Runtime.config["weather"].string("api_key") }

    /// Where the Mac is, about a kilometre either way (rounded before it leaves the Mac). The last
    /// fix stands in when macOS has none right now.
    private func locate(ask: Bool) async -> GeoPlace? {
        let last = UserDefaults.standard.data(forKey: Self.locationKey).flatMap { try? JSONDecoder().decode(GeoPlace.self, from: $0) }
        guard let location = await locator.locate(ask: ask) else { return last }
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        var name = last.flatMap { abs($0.latitude - lat) < 0.05 && abs($0.longitude - lon) < 0.05 ? $0.name : nil }
        if name == nil {
            name = try? await CLGeocoder().reverseGeocodeLocation(location).first.flatMap { $0.locality ?? $0.name }
        }
        let place = GeoPlace(name: name ?? "", latitude: lat, longitude: lon)
        if let data = try? JSONEncoder().encode(place) { UserDefaults.standard.set(data, forKey: Self.locationKey) }
        return place
    }

    /// Off for the app, or Location Services off for the whole Mac (CoreLocation says denied then too).
    var locationDenied: Bool { [.denied, .restricted].contains(locationStatus) }
    var locationAllowed: Bool { ![.notDetermined, .denied, .restricted].contains(locationStatus) }

    /// "Use my location" in the Today card and Settings › Daily. macOS asks on this click only, with
    /// the app in front: it lives in the menu bar, and an app in the background may get no prompt.
    /// After a no only System Settings can change it, so that opens at Location Services.
    func useMyLocation() {
        if locationDenied {
            PrivacyPane.open("Privacy_LocationServices")
            return
        }
        if locationStatus == .notDetermined { NSApp.activate() }
        refreshWeather(force: true, askLocation: true)
    }

    /// Allowed in System Settings (or in the prompt) while the card waits for a place: the weather
    /// comes without another click.
    private func locationChanged(_ status: CLAuthorizationStatus) {
        if status != locationStatus { locationStatus = status }
        guard locationAllowed, settings.place == nil, weatherStatus == .needsPlace else { return }
        refreshWeather(force: true)
    }

    /// Cities matching a typed name (Settings).
    func searchPlaces(_ name: String) async -> [GeoPlace] {
        guard name.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let data = try? await Self.fetch(URLRequest(url: OpenMeteo.geocodingURL(name: name, language: language, apiKey: Self.weatherKey))) else { return [] }
        return OpenMeteo.parsePlaces(data)
    }

    // MARK: Day progress

    var workDay: WorkDay { settings.workDay }

    // MARK: Health

    /// Oura's older personal access token, the fallback when no Oura app is connected.
    var ouraToken: String {
        get { Keychain.string(.ouraToken) ?? "" }
        set {
            let token = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard persists, token != ouraToken else { return }
            Keychain.set(token, for: .ouraToken)
            refreshHealth(force: true)
        }
    }

    var whoopSecret: String {
        get { Keychain.string(.whoopSecret) ?? "" }
        set { if persists { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .whoopSecret) } }
    }

    var ouraSecret: String {
        get { Keychain.string(.ouraSecret) ?? "" }
        set { if persists { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .ouraSecret) } }
    }

    /// Sources signed in with OAuth (read when health goes on, kept current on connect and disconnect).
    private(set) var connected: Set<HealthSource> = []

    func isConnected(_ source: HealthSource) -> Bool { connected.contains(source) }

    private static func tokenItem(_ source: HealthSource) -> Keychain.Item { source == .oura ? .ouraOAuth : .whoopToken }
    private func clientID(_ source: HealthSource) -> String {
        (source == .oura ? settings.ouraClientID : settings.whoopClientID).trimmingCharacters(in: .whitespaces)
    }
    private func secret(_ source: HealthSource) -> String { source == .oura ? ouraSecret : whoopSecret }
    private func redirect(_ source: HealthSource) -> String {
        source == .oura ? OuraAPI.redirectURI(scheme: Brand.urlScheme) : WhoopAPI.redirectURI(scheme: Brand.urlScheme)
    }
    private static func signedOut(_ source: HealthSource) -> String {
        source == .oura ? "Oura signed you out: connect again" : "WHOOP signed you out: connect again"
    }

    /// `force` (a new source or token) starts over even while a request runs; its answer is dropped.
    func refreshHealth(force: Bool = false) {
        guard isOn(.health), !preview, let source = settings.healthSource else {
            if isOn(.health), settings.healthSource == nil { healthStatus = .needsSetup }
            return
        }
        guard force || healthTask == nil else { return }
        healthTask?.cancel()
        healthGeneration += 1
        let generation = healthGeneration
        healthTask = Task { [weak self] in
            await self?.loadHealth(source, generation)
            if self?.healthGeneration == generation { self?.healthTask = nil }
        }
    }

    private func loadHealth(_ source: HealthSource, _ generation: Int) async {
        if health == nil { healthStatus = .loading }
        /// Still the request that counts, for the source that is set.
        var current: Bool { generation == healthGeneration && source == settings.healthSource }
        do {
            let day: HealthDay?
            switch source {
            case .oura: day = try await loadOura()
            case .whoop: day = try await loadWhoop()
            }
            guard current, let day else { return }
            withAnimation(Theme.snappy) { health = day }
            healthStatus = .ok
            Self.writeCache(day, "health.json")
            checkMorningLine(now: Date())
        } catch HealthError.notSetUp {
            if current { healthStatus = .needsSetup }
        } catch HealthError.rejected(let message) {
            if current { healthStatus = .failed(message) }
        } catch {
            if current { healthStatus = .failed(health == nil ? "Offline" : "Offline, showing the last scores") }
        }
    }

    private enum HealthError: Error {
        case notSetUp
        case rejected(String)
    }

    /// With a connected Oura app, else the personal access token.
    private func loadOura() async throws -> HealthDay? {
        let bearer: String, rejected: String
        if let token = try await oauthToken(.oura) {
            (bearer, rejected) = (token.access, Self.signedOut(.oura))
        } else {
            let token = ouraToken
            guard !token.isEmpty else { throw HealthError.notSetUp }
            (bearer, rejected) = (token, "Oura no longer accepts this token: connect your Oura app above")
        }
        let today = Date()
        let start = MorningLine.day(today.addingTimeInterval(-2 * 86_400)), end = MorningLine.day(today.addingTimeInterval(86_400))
        func get(_ collection: String) async throws -> (day: String, score: Int)? {
            var request = URLRequest(url: OuraAPI.url(collection, from: start, to: end))
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            return OuraAPI.latestScore(try await Self.fetch(request, rejected: rejected))
        }
        let sleep = try await get("daily_sleep")
        let readiness = try await get("daily_readiness")
        guard let day = [sleep?.day, readiness?.day].compactMap({ $0 }).max() else { return nil }
        return HealthDay(source: .oura, day: day, sleep: sleep?.day == day ? sleep?.score : nil,
                         readiness: readiness?.day == day ? readiness?.score : nil, fetched: Date())
    }

    private func loadWhoop() async throws -> HealthDay? {
        guard let token = try await oauthToken(.whoop) else { throw HealthError.notSetUp }
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            return try await Self.fetch(request, rejected: Self.signedOut(.whoop))
        }
        let recovery = WhoopAPI.parseRecovery(try await get(WhoopAPI.recoveryURL))
        let sleep = WhoopAPI.parseSleep(try await get(WhoopAPI.sleepURL))
        guard recovery != nil || sleep != nil else { return nil }
        return HealthDay(source: .whoop, day: recovery?.day ?? MorningLine.day(Date()), sleep: sleep, recovery: recovery?.recovery,
                         restingHeartRate: recovery?.restingHeartRate, hrv: recovery?.hrv, fetched: Date())
    }

    /// The saved OAuth token, refreshed when it has lapsed (Oura's refresh tokens work once, so
    /// the new one is saved straight away).
    private func oauthToken(_ source: HealthSource) async throws -> WhoopAPI.Token? {
        let item = Self.tokenItem(source)
        guard let token = Keychain.codable(WhoopAPI.Token.self, item) else { return nil }
        if token.isValid(at: Date()) { return token }
        let clientID = clientID(source)
        guard let refresh = token.refresh, !clientID.isEmpty else { throw HealthError.rejected(Self.signedOut(source)) }
        var request = URLRequest(url: source == .oura ? OuraAPI.tokenURL : WhoopAPI.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = source == .oura ? OuraAPI.refreshBody(refreshToken: refresh, clientID: clientID, secret: secret(source))
            : WhoopAPI.refreshBody(refreshToken: refresh, clientID: clientID, secret: secret(source))
        guard let fresh = WhoopAPI.parseToken(try await Self.fetch(request, rejected: Self.signedOut(source)), now: Date()) else {
            throw HealthError.rejected(source == .oura ? "Oura sent no token" : "WHOOP sent no token")
        }
        let saved = WhoopAPI.Token(access: fresh.access, refresh: fresh.refresh ?? refresh, expires: fresh.expires)
        Keychain.setCodable(saved, for: item)
        return saved
    }

    /// Opens the wearable's sign-in in the browser; it comes back to `<scheme>://oauth/<source>`.
    /// After five minutes without an answer the wait ends.
    func connect(_ source: HealthSource) {
        let clientID = clientID(source)
        guard !clientID.isEmpty else { return }
        let verifier = PKCE.verifier(), state = PKCE.state()
        login = (source, verifier, state)
        healthStatus = .loading
        let challenge = PKCE.challenge(for: verifier)
        NSWorkspace.shared.open(source == .oura
            ? OuraAPI.authorize(clientID: clientID, redirect: redirect(source), state: state, challenge: challenge)
            : WhoopAPI.authorize(clientID: clientID, redirect: redirect(source), state: state, challenge: challenge))
        loginTimeout?.cancel()
        loginTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.login?.state == state else { return }
            self.login = nil
            self.healthStatus = .failed("The sign-in didn't come back: connect again")
        }
    }

    /// `<scheme>://oauth/<source>?code=…&state=…`: trades the code for tokens.
    func handleOAuth(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let login, url.path == "/\(login.source.rawValue)", value("state") == login.state else {
            Log.app.error("Ignored an OAuth answer that wasn't asked for")
            return
        }
        let source = login.source
        self.login = nil
        loginTimeout?.cancel()
        guard let code = value("code") else {
            healthStatus = .failed(value("error_description") ?? value("error")
                ?? (source == .oura ? "Oura sign-in was cancelled" : "WHOOP sign-in was cancelled"))
            return
        }
        let clientID = clientID(source), secret = secret(source), redirect = redirect(source)
        Task {
            var request = URLRequest(url: source == .oura ? OuraAPI.tokenURL : WhoopAPI.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = source == .oura
                ? OuraAPI.tokenBody(code: code, verifier: login.verifier, clientID: clientID, secret: secret, redirect: redirect)
                : WhoopAPI.tokenBody(code: code, verifier: login.verifier, clientID: clientID, secret: secret, redirect: redirect)
            let refused = source == .oura ? "Oura didn't accept the app's client id or secret" : "WHOOP didn't accept the app's client id or secret"
            do {
                guard let token = WhoopAPI.parseToken(try await Self.fetch(request, rejected: refused), now: Date()) else {
                    throw HealthError.rejected(source == .oura ? "Oura sent no token" : "WHOOP sent no token")
                }
                Keychain.setCodable(token, for: Self.tokenItem(source))
                connected.insert(source)
                refreshHealth(force: true)
            } catch HealthError.rejected(let message) {
                healthStatus = .failed(message)
            } catch {
                healthStatus = .failed(source == .oura ? "Couldn't reach Oura" : "Couldn't reach WHOOP")
            }
        }
    }

    func disconnect(_ source: HealthSource) {
        Keychain.set(nil, for: Self.tokenItem(source))
        connected.remove(source)
        guard settings.healthSource == source else { return }
        health = nil
        refreshHealth(force: true)
    }

    // MARK: Morning line

    /// Today's scores (never yesterday's), from 5 in the morning, while someone is at the Mac;
    /// marked shown only once the line got through.
    private func checkMorningLine(now: Date) {
        guard isOn(.health), settings.morningLine, !preview, let health, !health.isEmpty, health.isFor(now),
              MorningLine.isDue(lastShown: UserDefaults.standard.string(forKey: Self.morningKey), now: now),
              MorningLine.userIsPresent(idleSeconds: Self.idleSeconds()),
              onMorningLine?(health, isOn(.weather) ? shownWeather : nil) == true else { return }
        UserDefaults.standard.set(MorningLine.day(now), forKey: Self.morningKey)
    }

    /// Seconds since the last key press, click or pointer move.
    private static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Network and cache

    private static func fetch(_ request: URLRequest, rejected: String = "Not allowed") async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 || status == 403 { throw HealthError.rejected(rejected) }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }

    private static func cacheURL(_ name: String) -> URL { Brand.supportFolder.appending(path: name) }

    private static func readCache<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: cacheURL(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func writeCache<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: Brand.supportFolder, withIntermediateDirectories: true)
        let url = cacheURL(name)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Previews

    /// Made-up weather, scores and notes; nothing is fetched or written.
    func usePreview(on features: Set<ToolFeature>, settings preset: DailySettings? = nil) {
        preview = true
        persists = false
        notes.persists = false
        if let preset { settings = preset }
        let now = Date()
        let hour = Calendar.current.date(bySetting: .minute, value: 0, of: now) ?? now
        let codes = [2, 2, 3, 61, 61, 3, 2, 1, 1, 0, 0, 0]
        let temps = [17.6, 18.2, 18.0, 16.4, 15.8, 16.1, 16.9, 17.3, 16.2, 14.8, 13.5, 12.9]
        weather = WeatherReport(temperature: 17.6, code: 2, isDay: true, high: 19.4, low: 11.2,
                                hours: (0..<12).map { index in
                                    WeatherHour(time: hour.addingTimeInterval(Double(index) * 3600), temperature: temps[index], code: codes[index],
                                                isDay: index < 8, precipitation: [0, 5, 20, 70, 65, 30, 10, 0, 0, 0, 0, 0][index])
                                },
                                unit: .celsius, fetched: now, place: "Lisbon")
        weatherStatus = .ok
        if self.settings.healthSource == .whoop {
            health = HealthDay(source: .whoop, day: MorningLine.day(now), sleep: 91, recovery: 72, restingHeartRate: 52, hrv: 68, fetched: now)
        } else {
            health = HealthDay(source: .oura, day: MorningLine.day(now), sleep: 84, readiness: 80, fetched: now)
        }
        healthStatus = .ok
        notes.usePreview()
        previewFeatures = features
        on = features
    }

    /// A preview of the tools before anything is set up.
    func clearPreviewData() {
        weather = nil
        weatherStatus = .needsPlace
        health = nil
        healthStatus = .needsSetup
        settings.healthSource = nil
    }
}

/// One location fix from CoreLocation, approximate. macOS asks once, on the user's click; after a
/// no, it stays no.
@MainActor
private final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    /// Every change of the app's authorization, also the ones made in System Settings.
    var onStatusChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Not asked yet: only with `ask` (a click) does macOS put up its prompt; otherwise nil.
    func locate(ask: Bool) async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined where !ask: return nil
        default: break
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            // macOS may never answer (no Wi-Fi, prompt left open): give up after a while.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            onStatusChange?(status)
            guard !waiting.isEmpty else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: finish(nil)
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
