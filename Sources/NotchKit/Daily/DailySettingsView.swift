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
                Text("Weather comes from Open-Meteo, free and without an account; only the city or a location rounded to about a kilometre leaves the Mac. Tokens for Oura and WHOOP stay in the Keychain.")
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
        } else if daily.locationDenied {
            Text("Location is off for \(Brand.bundleName) in System Settings › Privacy & Security › Location Services. Type a city instead.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Picker("Unit", selection: $daily.settings.unit) {
            ForEach(TemperatureUnit.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
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
        LabeledContent("Notes folder") {
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
    @State private var ouraToken = ""
    @State private var whoopSecret = ""

    var body: some View {
        Picker("Sleep and recovery from", selection: $daily.settings.healthSource) {
            Text("Choose").tag(HealthSource?.none)
            ForEach(HealthSource.allCases, id: \.self) { Text($0.title).tag(HealthSource?.some($0)) }
        }
        switch daily.settings.healthSource {
        case .oura:
            SecureField("Personal access token", text: $ouraToken, prompt: Text("from cloud.ouraring.com"))
                .task(id: ouraToken) {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    daily.ouraToken = ouraToken
                }
                // Read when the field shows; typing saves to the Keychain.
                .onAppear { ouraToken = daily.ouraToken }
            Link("Get a token from Oura", destination: OuraAPI.tokenPage)
        case .whoop:
            TextField("Client ID", text: $daily.settings.whoopClientID, prompt: Text("from developer.whoop.com"))
            SecureField("Client secret", text: $whoopSecret)
                .onChange(of: whoopSecret) { _, value in daily.whoopSecret = value }
                .onAppear { whoopSecret = daily.whoopSecret }
            LabeledContent("Redirect URL") {
                Text(WhoopAPI.redirectURI(scheme: Brand.urlScheme)).textSelection(.enabled).foregroundStyle(.secondary)
            }
            LabeledContent("Account") {
                if daily.whoopConnected {
                    Button("Disconnect") { daily.disconnectWhoop() }
                } else {
                    Button("Connect WHOOP") { daily.connectWhoop() }
                        .disabled(daily.settings.whoopClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Register an app at developer.whoop.com with the redirect URL above and the scopes for recovery, sleep, cycles and offline access, then enter its client ID and secret here.")
                .font(.callout).foregroundStyle(.secondary)
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
