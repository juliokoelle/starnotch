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
            onEarsChanged?()
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
    private(set) var healthStatus = HealthStatus.idle
    /// The calendar shows the day card instead of the agenda.
    var cardShown = false
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
    /// The ears' content changed (a tool or an ear option switched).
    @ObservationIgnored var onEarsChanged: (() -> Void)?
    /// Once a morning: last night's scores and today's weather.
    @ObservationIgnored var onMorningLine: ((HealthDay, WeatherReport?) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private let locator = Locator()
    @ObservationIgnored private var whoopLogin: (verifier: String, state: String)?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    static let settingsKey = "dailySettings"
    private static let locationKey = "daily.location"
    private static let morningKey = "daily.morningShown"

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DailySettings.self, from: $0) }
        settings = stored ?? DailySettings(unit: DailySettings.defaultUnit(for: .current))
        weather = Self.readCache(WeatherReport.self, "weather.json")
        health = Self.readCache(HealthDay.self, "health.json")
        notes.folder = notesFolder
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
        onEarsChanged?()
        guard !preview else { return }
        if added.contains(.weather) { refreshWeather() }
        if added.contains(.health) {
            whoopConnected = Keychain.codable(WhoopAPI.Token.self, .whoopToken) != nil
            refreshHealth()
        }
        if added.contains(.notes) { notes.load() }
        if on.isDisjoint(with: [.weather, .health, .dayProgress]) { stopLoop() } else { startLoop() }
    }

    /// Every minute while weather, day progress or health is on: the clock, what is stale, the morning line.
    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
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

    /// The weather to show: fresh enough and in the unit set.
    var shownWeather: WeatherReport? {
        guard let weather, weather.isUsable(at: Date()), weather.unit == settings.unit else { return nil }
        return weather
    }

    func refreshWeather(force: Bool = false) {
        guard isOn(.weather), !preview, weatherTask == nil else { return }
        if !force, let weather, weather.isFresh(at: Date()), weather.unit == settings.unit { return }
        weatherTask = Task { [weak self] in
            await self?.loadWeather()
            self?.weatherTask = nil
        }
    }

    private func loadWeather() async {
        weatherStatus = weather == nil ? .loading : weatherStatus
        let place: GeoPlace
        if let chosen = settings.place {
            place = chosen
        } else {
            weatherStatus = weather == nil ? .locating : weatherStatus
            guard let found = await locate() else {
                weatherStatus = .needsPlace
                return
            }
            place = found
        }
        let url = OpenMeteo.forecastURL(latitude: place.latitude, longitude: place.longitude, unit: settings.unit)
        do {
            let data = try await Self.fetch(URLRequest(url: url))
            let report = try OpenMeteo.parseForecast(data, unit: settings.unit, fetched: Date(), place: place.name)
            withAnimation(Theme.snappy) { weather = report }
            weatherStatus = .ok
            Self.writeCache(report, "weather.json")
        } catch {
            // Offline: the last forecast stays while it is usable.
            weatherStatus = .offline
            Log.app.info("Weather: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where the Mac is, about a kilometre either way (rounded before it leaves the Mac). The last
    /// fix stands in when macOS has none right now.
    private func locate() async -> GeoPlace? {
        let last = UserDefaults.standard.data(forKey: Self.locationKey).flatMap { try? JSONDecoder().decode(GeoPlace.self, from: $0) }
        guard let location = await locator.locate() else { return last }
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

    var locationDenied: Bool { [.denied, .restricted].contains(locator.status) }

    /// Cities matching a typed name (Settings).
    func searchPlaces(_ name: String) async -> [GeoPlace] {
        guard name.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let data = try? await Self.fetch(URLRequest(url: OpenMeteo.geocodingURL(name: name, language: language))) else { return [] }
        return OpenMeteo.parsePlaces(data)
    }

    // MARK: Day progress

    var workDay: WorkDay { settings.workDay }

    // MARK: Health

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

    /// A WHOOP token is in the Keychain (read when health goes on, kept current on connect and disconnect).
    private(set) var whoopConnected = false

    func refreshHealth(force: Bool = false) {
        guard isOn(.health), !preview, healthTask == nil, let source = settings.healthSource else {
            if isOn(.health), settings.healthSource == nil { healthStatus = .needsSetup }
            return
        }
        healthTask = Task { [weak self] in
            await self?.loadHealth(source)
            self?.healthTask = nil
        }
    }

    private func loadHealth(_ source: HealthSource) async {
        if health == nil { healthStatus = .loading }
        do {
            let day: HealthDay?
            switch source {
            case .oura: day = try await loadOura()
            case .whoop: day = try await loadWhoop()
            }
            guard let day else { return }
            withAnimation(Theme.snappy) { health = day }
            healthStatus = .ok
            Self.writeCache(day, "health.json")
            checkMorningLine(now: Date())
        } catch HealthError.notSetUp {
            healthStatus = .needsSetup
        } catch HealthError.rejected(let message) {
            healthStatus = .failed(message)
        } catch {
            healthStatus = .failed(health == nil ? "Offline" : "Offline, showing the last scores")
        }
    }

    private enum HealthError: Error {
        case notSetUp
        case rejected(String)
    }

    private func loadOura() async throws -> HealthDay? {
        let token = ouraToken
        guard !token.isEmpty else { throw HealthError.notSetUp }
        let today = Date()
        let start = MorningLine.day(today.addingTimeInterval(-2 * 86_400)), end = MorningLine.day(today.addingTimeInterval(86_400))
        func get(_ collection: String) async throws -> (day: String, score: Int)? {
            var request = URLRequest(url: OuraAPI.url(collection, from: start, to: end))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return OuraAPI.latestScore(try await Self.fetch(request, rejected: "Oura didn't accept the token"))
        }
        let sleep = try await get("daily_sleep")
        let readiness = try await get("daily_readiness")
        guard let day = [sleep?.day, readiness?.day].compactMap({ $0 }).max() else { return nil }
        return HealthDay(source: .oura, day: day, sleep: sleep?.day == day ? sleep?.score : nil,
                         readiness: readiness?.day == day ? readiness?.score : nil, fetched: Date())
    }

    private func loadWhoop() async throws -> HealthDay? {
        guard let token = try await whoopToken() else { throw HealthError.notSetUp }
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
            return try await Self.fetch(request, rejected: "WHOOP signed you out: connect again")
        }
        let recovery = WhoopAPI.parseRecovery(try await get(WhoopAPI.recoveryURL))
        let sleep = WhoopAPI.parseSleep(try await get(WhoopAPI.sleepURL))
        guard recovery != nil || sleep != nil else { return nil }
        return HealthDay(source: .whoop, day: recovery?.day ?? MorningLine.day(Date()), sleep: sleep, recovery: recovery?.recovery,
                         restingHeartRate: recovery?.restingHeartRate, hrv: recovery?.hrv, fetched: Date())
    }

    /// The saved WHOOP token, refreshed when it has lapsed.
    private func whoopToken() async throws -> WhoopAPI.Token? {
        guard let token = Keychain.codable(WhoopAPI.Token.self, .whoopToken) else { return nil }
        if token.isValid(at: Date()) { return token }
        guard let refresh = token.refresh, !settings.whoopClientID.isEmpty else { throw HealthError.rejected("WHOOP signed you out: connect again") }
        var request = URLRequest(url: WhoopAPI.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = WhoopAPI.refreshBody(refreshToken: refresh, clientID: settings.whoopClientID, secret: whoopSecret)
        guard let fresh = WhoopAPI.parseToken(try await Self.fetch(request, rejected: "WHOOP signed you out: connect again"), now: Date()) else {
            throw HealthError.rejected("WHOOP sent no token")
        }
        Keychain.setCodable(WhoopAPI.Token(access: fresh.access, refresh: fresh.refresh ?? refresh, expires: fresh.expires), for: .whoopToken)
        return fresh
    }

    /// Opens WHOOP's sign-in in the browser; it comes back to `<scheme>://oauth/whoop`.
    func connectWhoop() {
        let clientID = settings.whoopClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { return }
        let verifier = PKCE.verifier(), state = PKCE.state()
        whoopLogin = (verifier, state)
        healthStatus = .loading
        NSWorkspace.shared.open(WhoopAPI.authorize(clientID: clientID, redirect: WhoopAPI.redirectURI(scheme: Brand.urlScheme),
                                                   state: state, challenge: PKCE.challenge(for: verifier)))
    }

    /// `<scheme>://oauth/whoop?code=…&state=…`: trades the code for tokens.
    func handleOAuth(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard url.path == "/whoop", let login = whoopLogin, value("state") == login.state else {
            Log.app.error("Ignored an OAuth answer that wasn't asked for")
            return
        }
        whoopLogin = nil
        guard let code = value("code") else {
            healthStatus = .failed(value("error_description") ?? value("error") ?? "WHOOP sign-in was cancelled")
            return
        }
        Task {
            var request = URLRequest(url: WhoopAPI.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = WhoopAPI.tokenBody(code: code, verifier: login.verifier, clientID: settings.whoopClientID,
                                                  secret: whoopSecret, redirect: WhoopAPI.redirectURI(scheme: Brand.urlScheme))
            do {
                guard let token = WhoopAPI.parseToken(try await Self.fetch(request, rejected: "WHOOP didn't accept the app's client id or secret"),
                                                      now: Date()) else { throw HealthError.rejected("WHOOP sent no token") }
                Keychain.setCodable(token, for: .whoopToken)
                whoopConnected = true
                refreshHealth(force: true)
            } catch HealthError.rejected(let message) {
                healthStatus = .failed(message)
            } catch {
                healthStatus = .failed("Couldn't reach WHOOP")
            }
        }
    }

    func disconnectWhoop() {
        Keychain.set(nil, for: .whoopToken)
        whoopConnected = false
        if settings.healthSource == .whoop { health = nil; healthStatus = .needsSetup }
    }

    // MARK: Morning line

    private func checkMorningLine(now: Date) {
        guard isOn(.health), settings.morningLine, !preview, let health, !health.isEmpty,
              health.day == MorningLine.day(now) || now.timeIntervalSince(health.fetched) < 3600,
              MorningLine.isDue(lastShown: UserDefaults.standard.string(forKey: Self.morningKey), now: now) else { return }
        UserDefaults.standard.set(MorningLine.day(now), forKey: Self.morningKey)
        onMorningLine?(health, isOn(.weather) ? shownWeather : nil)
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
        onEarsChanged?()
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

/// One location fix from CoreLocation, approximate. macOS asks once; after a no, it stays no.
@MainActor
private final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func locate() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
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
