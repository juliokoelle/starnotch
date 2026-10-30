import AppKit
import NotchCore
import SwiftUI

/// Settings › Daily: only the details of the daily tools that are on (weather, day progress,
/// notes, sleep and recovery); nothing shows while all four are off.
struct DailySettingsSection: View {
    @Bindable var state: AppState
    @Bindable var daily: DailyStore = .shared

    var body: some View {
        let on = { (feature: ToolFeature) in ToolSwitches.isOn(feature, in: state.settings) }
        if on(.weather) || on(.dayProgress) || on(.notes) || on(.health) {
            Section {
                if on(.weather) { WeatherSettings(daily: daily) }
                if on(.dayProgress) { DayProgressSettings(daily: daily) }
                if on(.notes) { NotesFolderSettings(daily: daily) }
                if on(.health) { HealthSettings(daily: daily) }
            } header: {
                Text("Daily")
            } footer: {
                // Open-Meteo's data is CC BY 4.0: the credit with its links.
                Text("Weather data by [Open-Meteo.com](https://open-meteo.com), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Only the city or a location rounded to about a kilometre leaves the Mac. Tokens for Oura and WHOOP stay in the Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WeatherSettings: View {
    @Bindable var daily: DailyStore
    @State private var byCity: Bool
    @State private var query: String
    @State private var results: [GeoPlace] = []

    init(daily: DailyStore) {
        self.daily = daily
        _byCity = State(initialValue: daily.settings.place != nil)
        _query = State(initialValue: daily.settings.place?.label ?? "")
    }

    var body: some View {
        Picker("Weather for", selection: Binding(get: { byCity }, set: { city in
            byCity = city
            if !city { daily.settings.place = nil; query = ""; results = [] }
        })) {
            Text("Where I am").tag(false)
            Text("A city").tag(true)
        }
        if byCity {
            TextField("City", text: $query, prompt: Text("Type a city"))
                .task(id: query) {
                    guard query != daily.settings.place?.label else { results = []; return }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    results = await daily.searchPlaces(query)
                }
            ForEach(results, id: \.self) { place in
                Button {
                    daily.settings.place = place
                    query = place.label
                    results = []
                } label: {
                    Label(place.fullLabel, systemImage: "mappin").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else if !daily.locationAllowed || daily.weatherStatus == .needsPlace {
            LabeledContent {
                Button("Use my location") { daily.useMyLocation() }
            } label: {
                if daily.locationDenied {
                    Text("Location is off")
                    Text("Opens System Settings › Privacy & Security › Location Services: turn on \(Brand.bundleName) there. Or type a city instead.")
                } else {
                    Text("Location")
                    Text("macOS asks once, on this click. Approximate is enough.")
                }
            }
        }
        LabeledContent("Unit") {
            GlassSegmented(label: Localization.string("Unit"), selection: $daily.settings.unit, options: TemperatureUnit.allCases.map { ($0, $0.title) })
        }
        Toggle(isOn: $daily.settings.weatherInEar) {
            Text("Weather beside the notch")
            Text("Symbol and temperature at rest, while nothing else needs the space.")
        }
    }
}

private struct DayProgressSettings: View {
    @Bindable var daily: DailyStore

    var body: some View {
        HStack {
            Text("Work day")
            Spacer()
            DatePicker("Starts", selection: minutes(\.start), displayedComponents: .hourAndMinute).labelsHidden()
            Text("–").foregroundStyle(.secondary)
            DatePicker("Ends", selection: minutes(\.end), displayedComponents: .hourAndMinute).labelsHidden()
        }
        Toggle("Weekends count", isOn: $daily.settings.workDay.weekends)
        Toggle(isOn: $daily.settings.progressInEar) {
            Text("Day progress beside the notch")
            Text("A thin ring at rest while the work day runs.")
        }
    }

    /// A minute of the day as a date today, for the time pickers.
    private func minutes(_ key: WritableKeyPath<WorkDay, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(daily.settings.workDay[keyPath: key]) * 60)
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            daily.settings.workDay[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

private struct NotesFolderSettings: View {
    @Bindable var daily: DailyStore

    var body: some View {
        LabeledContent("Notepad folder") {
            HStack(spacing: 8) {
                Text((daily.notesFolder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(daily.notesFolder.path)
                Button("Choose…") { choose() }
                if daily.settings.notesFolder != nil {
                    Button("Default") { daily.settings.notesFolder = nil }
                }
            }
        }
    }

    /// Any folder will do, a vault folder too: the notes are plain Markdown files.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = Localization.string("Use folder")
        panel.directoryURL = daily.notesFolder
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        daily.settings.notesFolder = url.path
    }
}

private struct HealthSettings: View {
    @Bindable var daily: DailyStore

    var body: some View {
        Picker("Sleep and recovery from", selection: $daily.settings.healthSource) {
            Text("Choose").tag(HealthSource?.none)
            ForEach(HealthSource.allCases, id: \.self) { Text($0.title).tag(HealthSource?.some($0)) }
        }
        switch daily.settings.healthSource {
        case .oura:
            OAuthAppFields(daily: daily, source: .oura, clientID: $daily.settings.ouraClientID)
            OuraTokenField(daily: daily)
        case .whoop:
            OAuthAppFields(daily: daily, source: .whoop, clientID: $daily.settings.whoopClientID)
        case nil:
            EmptyView()
        }
        if case .failed(let message) = daily.healthStatus {
            Label(LocalizedStringKey(message), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
        if daily.settings.healthSource != nil {
            Toggle(isOn: $daily.settings.morningLine) {
                Text("Morning line")
                Text("Last night's scores once a morning, the first time you use the Mac.")
            }
        }
    }
}

/// The user's own developer app at Oura or WHOOP: client ID, secret, the redirect URL to enter
/// there, and the sign-in.
private struct OAuthAppFields: View {
    @Bindable var daily: DailyStore
    let source: HealthSource
    @Binding var clientID: String
    @State private var secret = ""

    var body: some View {
        TextField("Client ID", text: $clientID, prompt: Text(source == .oura ? "from cloud.ouraring.com" : "from developer.whoop.com"))
        SecureField("Client secret", text: $secret)
            .onChange(of: secret) { _, value in
                if source == .oura { daily.ouraSecret = value } else { daily.whoopSecret = value }
            }
            .onAppear { secret = source == .oura ? daily.ouraSecret : daily.whoopSecret }
        LabeledContent("Redirect URL") {
            Text(source == .oura ? OuraAPI.redirectURI(scheme: Brand.urlScheme) : WhoopAPI.redirectURI(scheme: Brand.urlScheme))
                .textSelection(.enabled).foregroundStyle(.secondary)
        }
        LabeledContent("Account") {
            if daily.isConnected(source) {
                Button("Disconnect") { daily.disconnect(source) }
            } else {
                Button(source == .oura ? "Connect Oura" : "Connect WHOOP") { daily.connect(source) }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if source == .oura {
            Text("Register an app at cloud.ouraring.com with the redirect URL above and the daily scope, then enter its client ID and secret here.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Register an app at developer.whoop.com with the redirect URL above and the scopes for recovery, sleep, cycles and offline access, then enter its client ID and secret here.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Oura's older personal access token, folded away: the fallback while no Oura app is connected.
private struct OuraTokenField: View {
    @Bindable var daily: DailyStore
    @State private var token = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Personal access token instead", isExpanded: $expanded) {
            SecureField("Personal access token", text: $token, prompt: Text("from cloud.ouraring.com"))
                .task(id: token) {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    daily.ouraToken = token
                }
            Link("Get a token from Oura", destination: OuraAPI.tokenPage)
        }
        // Read when the field shows; typing saves to the Keychain. Open when a token is saved.
        .onAppear {
            token = daily.ouraToken
            expanded = !token.isEmpty
        }
    }
}
