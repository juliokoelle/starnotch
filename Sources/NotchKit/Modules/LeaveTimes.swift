import AppKit
import CoreLocation
import MapKit
import NotchCore
import Observation

/// Time to leave (Settings › Tools): for today's events with a place, how long the way there
/// takes, the leave time in the event's card and a line on the island when it's time to go, once
/// per event. Calendar's own travel time comes first; else Apple Maps works it out from where the
/// Mac is, with the location permission the weather uses, asked only on a click in the card.
/// Quiet without a place, a location or a route.
@MainActor
@Observable
final class LeaveTimes {
    struct Estimate: Equatable {
        var travel: TimeInterval
        /// Set in Calendar; else Apple Maps' answer for `mode`.
        var fromCalendar: Bool
        var mode: TravelMode
        var found: Date
    }

    /// By event id.
    private(set) var estimates: [String: Estimate] = [:]
    /// Off forgets every answer.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { update(today) } else { forget() }
        }
    }
    var mode = TravelMode.driving {
        didSet {
            guard mode != oldValue else { return }
            // Apple Maps' answers were for the other way of travelling, also the one on its way:
            // it's dropped and a fresh lookup starts.
            lookup?.cancel()
            lookup = nil
            generation += 1
            estimates = estimates.filter { $0.value.fromCalendar }
            failed = [:]
            update(today)
        }
    }
    /// It's time to go: the app shows the line; true when it got through (else the next read tries again).
    @ObservationIgnored var onLeave: ((CalendarModule.Meeting, Estimate) -> Bool)?
    /// Previews and the sample data keep nothing.
    @ObservationIgnored var persists = true

    @ObservationIgnored private var today: [CalendarModule.Meeting] = []
    /// Places found for a location's text, so each is searched once.
    @ObservationIgnored private var places: [String: MKMapItem] = [:]
    /// When a lookup found no place or no route, by event id.
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var lookup: Task<Void, Never>?
    /// Counts lookups: one that ends after `forget` or a new mode keeps no answer and doesn't
    /// clear a newer one.
    @ObservationIgnored private var generation = 0
    /// Closer than the weather's fix: a few kilometres off is minutes off.
    @ObservationIgnored private lazy var locator = Locator(accuracy: kCLLocationAccuracyHundredMeters)
    @ObservationIgnored private lazy var alerts: LeaveAlerts = UserDefaults.standard.data(forKey: Self.alertsKey)
        .flatMap { try? JSONDecoder().decode(LeaveAlerts.self, from: $0) } ?? LeaveAlerts()

    private static let alertsKey = "timeToLeave.alerted"

    /// The calendar read today's events (every 15 s and on changes): Calendar's travel times, the
    /// line when it's due, then Apple Maps for what is missing or old.
    func update(_ events: [CalendarModule.Meeting], now: Date = Date()) {
        today = events
        guard enabled else { return }
        let ids = Set(events.map(\.id))
        if estimates.keys.contains(where: { !ids.contains($0) }) { estimates = estimates.filter { ids.contains($0.key) } }
        for event in events {
            guard let travel = event.travelTime, estimates[event.id]?.travel != travel || estimates[event.id]?.fromCalendar != true else { continue }
            estimates[event.id] = Estimate(travel: travel, fromCalendar: true, mode: mode, found: now)
        }
        checkDue(now: now)
        lookUpMissing(now: now)
    }

    /// The card's link: shown for an event with a place while macOS has never asked for the location.
    func offersLocation(for id: String) -> Bool {
        guard enabled, estimates[id] == nil, DailyStore.shared.locationStatus == .notDetermined,
              let event = today.first(where: { $0.id == id }) else { return false }
        return event.travelTime == nil && Self.hasPlace(event)
    }

    /// The card's "Use my location": macOS asks on this click, with the app in front (it lives in
    /// the menu bar, and an app in the background may get no prompt). After a no only System
    /// Settings can change it.
    func useMyLocation() {
        Haptics.tick()
        if DailyStore.shared.locationDenied {
            PrivacyPane.open("Privacy_LocationServices")
            return
        }
        NSApp.activate()
        Task { [weak self] in
            guard let self, await self.locator.locate(ask: true) != nil else { return }
            self.failed = [:]
            self.update(self.today)
        }
    }

    /// Apple Maps with the way there, for the line's click.
    func mapsURL(for event: CalendarModule.Meeting) -> URL? {
        guard let destination = event.coordinate.map({ "\($0.latitude),\($0.longitude)" }) ?? event.location else { return nil }
        var link = URLComponents(string: "https://maps.apple.com/")
        link?.queryItems = [URLQueryItem(name: "daddr", value: destination), URLQueryItem(name: "dirflg", value: mode.mapsFlag)]
        return link?.url
    }

    /// Previews: made-up answers and events; nothing is looked up or kept.
    func usePreview(_ made: [String: Estimate], today events: [CalendarModule.Meeting]) {
        persists = false
        enabled = true
        today = events
        estimates = made
    }

    // MARK: Due

    private func checkDue(now: Date) {
        guard enabled else { return }
        let day = MorningLine.day(now)
        for event in today {
            guard let estimate = estimates[event.id], TimeToLeave.isDue(start: event.start, travel: estimate.travel, now: now),
                  !alerts.contains(event.id, day: day), onLeave?(event, estimate) == true else { continue }
            alerts.insert(event.id, day: day)
            if persists, let data = try? JSONEncoder().encode(alerts) { UserDefaults.standard.set(data, forKey: Self.alertsKey) }
        }
    }

    // MARK: Apple Maps

    private static func hasPlace(_ event: CalendarModule.Meeting) -> Bool {
        TimeToLeave.hasPlace(location: event.location, hasCoordinate: event.coordinate != nil,
                             hasCallLink: event.link != nil, isRoom: event.isRoom)
    }

    /// One lookup at a time; never before the location is allowed.
    private func lookUpMissing(now: Date) {
        guard lookup == nil else { return }
        let wanted = today.filter { event in
            event.travelTime == nil && Self.hasPlace(event)
                && TimeToLeave.needsLookup(start: event.start, now: now, found: estimates[event.id]?.found,
                                           travel: estimates[event.id]?.travel, failed: failed[event.id])
        }
        guard !wanted.isEmpty, ![.notDetermined, .denied, .restricted].contains(locator.status) else { return }
        let mode = mode
        generation += 1
        let mine = generation
        lookup = Task { [weak self] in
            await self?.lookUp(wanted, mode: mode, generation: mine)
            if self?.generation == mine { self?.lookup = nil }
        }
    }

    /// One location fix, then each event's place and route in turn. A failed refresh keeps the
    /// last answer; a route that's too short or too long drops it. Off, another mode or a newer
    /// lookup while waiting: the answer is old and the lookup stops.
    private func lookUp(_ events: [CalendarModule.Meeting], mode: TravelMode, generation mine: Int) async {
        guard let here = await locator.locate(ask: false) else {
            if isCurrent(mine, mode: mode) { for event in events { failed[event.id] = Date() } }
            return
        }
        for event in events {
            guard isCurrent(mine, mode: mode) else { return }
            let travel = await route(to: event, from: here, mode: mode)
            guard isCurrent(mine, mode: mode) else { return }
            guard let travel else {
                failed[event.id] = Date()
                continue
            }
            if TimeToLeave.usable(travel) {
                estimates[event.id] = Estimate(travel: travel, fromCalendar: false, mode: mode, found: Date())
                failed[event.id] = nil
            } else {
                // Already there, or not a way across town: nothing to say.
                estimates[event.id] = nil
                failed[event.id] = Date()
            }
        }
        // A fresh answer may be due at once.
        checkDue(now: Date())
    }

    private func isCurrent(_ mine: Int, mode: TravelMode) -> Bool {
        generation == mine && enabled && self.mode == mode
    }

    private func route(to event: CalendarModule.Meeting, from here: CLLocation, mode: TravelMode) async -> TimeInterval? {
        // Stopped while the place was searched: no request for the way.
        guard let destination = await place(of: event, near: here), !Task.isCancelled else { return nil }
        let request = MKDirections.Request()
        request.source = Self.item(at: here.coordinate)
        request.destination = destination
        request.transportType = mode.transport
        request.departureDate = Date()
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    private func place(of event: CalendarModule.Meeting, near here: CLLocation) async -> MKMapItem? {
        if let spot = event.coordinate { return Self.item(at: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)) }
        guard let text = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let known = places[text] { return known }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        // Around the Mac first: "Factory Campus" is the one in this city.
        request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        guard let found = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        places[text] = found
        return found
    }

    private static func item(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    private func forget() {
        lookup?.cancel()
        lookup = nil
        generation += 1
        estimates = [:]
        failed = [:]
        places = [:]
    }
}

extension TravelMode {
    var transport: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .transit: .transit
        case .walking: .walking
        }
    }

    /// Apple Maps' `dirflg`: driving, public transport, walking.
    var mapsFlag: String {
        switch self {
        case .driving: "d"
        case .transit: "r"
        case .walking: "w"
        }
    }
}
