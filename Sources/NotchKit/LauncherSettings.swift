import AppKit
import NotchCore
import SwiftUI

/// Settings › Shortcuts and apps, while the launcher is on: what it holds, in its order (up,
/// down, remove), and two pickers that add Apple Shortcuts (searched by name) and apps.
struct LauncherSettingsSection: View {
    @Bindable var state: AppState
    let catalog: AppCatalog

    var body: some View {
        if ToolSwitches.isOn(.launcher, in: state.settings) {
            let items = state.settings.launcher
            Section {
                if items.isEmpty {
                    Text("Nothing added yet. Add shortcuts and apps here; they run from the Launcher in the Tools tab.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LauncherSettingsRow(item: item, first: index == 0, last: index == items.count - 1) { step in
                        withAnimation(Theme.snappy) { Launcher.move(item.id, by: step, in: &state.settings.launcher) }
                    } remove: {
                        withAnimation(Theme.snappy) { Launcher.remove(item.id, from: &state.settings.launcher) }
                    }
                }
                HStack(spacing: 8) {
                    AddButton(title: "Add shortcut", symbol: "square.2.layers.3d") { ShortcutPicker(state: state) }
                    AddButton(title: "Add app", symbol: "app") { LauncherAppPicker(state: state, catalog: catalog) }
                    Spacer()
                }
                .padding(.vertical, 2)
            } header: {
                Text("Shortcuts and apps")
            } footer: {
                Text("Shortcuts run with the shortcuts tool that comes with macOS; one that asks for something shows its own window. Both are also on ⌃⌥K.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension LauncherSettingsSection {
    private static var previewWindow: NSWindow?

    /// `--preview launcher-settings`: the section with made-up items in a window of its own,
    /// brought forward without taking the keyboard from the app in front.
    static func showPreview(state: AppState) {
        ToolSwitches.set(.launcher, on: true, in: &state.settings)
        state.settings.launcher = [.shortcut("Morning routine"),
                                   .app(SlotApp(bundleID: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app")),
                                   .shortcut("Log water"),
                                   .app(SlotApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"))]
        let view = Form { LauncherSettingsSection(state: state, catalog: AppCatalog()) }
            .formStyle(.grouped).dashboardControls().frame(width: 560, height: 360)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.title = "Shortcuts and apps"
        window.isReleasedWhenClosed = false
        window.setFrameTopLeftPoint(NSPoint(x: 476, y: (NSScreen.main?.frame.maxY ?? 982) - 60))
        window.orderFrontRegardless()
        previewWindow = window
    }
}

private struct LauncherSettingsRow: View {
    let item: LauncherItem
    let first: Bool
    let last: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let app = item.app {
                    Image(nsImage: AppIcons.icon(for: app, size: 48)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "square.2.layers.3d.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.kind == .app ? "App" : "Shortcut").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            icon("chevron.up", help: "Move up", enabled: !first) { move(-1) }
            icon("chevron.down", help: "Move down", enabled: !last) { move(1) }
            icon("xmark", help: "Remove", enabled: true, action: remove)
        }
        .padding(.vertical, 2)
    }

    private func icon(_ symbol: String, help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// "Add shortcut" and "Add app": the accent pill of the slot rows, opening its picker.
private struct AddButton<Picker: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let picker: () -> Picker
    @State private var open = false

    var body: some View {
        Button {
            Haptics.tick()
            open.toggle()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .popover(isPresented: $open, arrowEdge: .bottom) { picker() }
    }
}

/// The user's shortcuts from `shortcuts list`, searched by name; a click adds one and the list
/// stays open for the next.
private struct ShortcutPicker: View {
    @Bindable var state: AppState
    @State private var names: [String]?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickerSearchField(prompt: "Search shortcuts", query: $query)
            if let names {
                let matches = Launcher.shortcuts(names, matching: query, besides: state.settings.launcher)
                if names.isEmpty {
                    Text(ShortcutsTool.isAvailable ? "No shortcuts yet. Make one in the Shortcuts app." : "The shortcuts tool isn't on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if matches.isEmpty {
                    Text(query.isEmpty ? "Every shortcut is added." : "No shortcut matches.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    PickerList(rows: matches.map { name in
                        PickerList.Row(id: name, title: name, icon: nil) {
                            Launcher.add(.shortcut(name), to: &state.settings.launcher)
                        }
                    })
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 340)
        .task { names = await ShortcutsTool.list() }
    }
}

/// The apps in the usual folders, searched by name, or any app through an open panel.
private struct LauncherAppPicker: View {
    @Bindable var state: AppState
    let catalog: AppCatalog
    @State private var query = ""

    var body: some View {
        let added = Set(state.settings.launcher.compactMap { $0.app?.bundleID })
        let apps = (catalog.notchApps + catalog.otherApps)
            .filter { !added.contains($0.bundleID) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 10) {
            PickerSearchField(prompt: "Search apps", query: $query)
            if apps.isEmpty {
                Text("No app matches.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                PickerList(rows: apps.map { app in
                    PickerList.Row(id: app.bundleID, title: app.name, icon: NSWorkspace.shared.icon(forFile: app.url.path)) {
                        Launcher.add(.app(app.slotApp), to: &state.settings.launcher)
                    }
                })
            }
            Divider()
            Button("Choose App…") {
                Haptics.tick()
                if let app = catalog.chooseApp() { Launcher.add(.app(app.slotApp), to: &state.settings.launcher) }
            }
            .buttonStyle(PressScale())
            .foregroundStyle(Theme.accent)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { catalog.refresh() }
    }
}

private struct PickerSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $query).textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Rows to click in a picker, scrolling past about eight.
private struct PickerList: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        let icon: NSImage?
        let add: () -> Void
    }

    let rows: [Row]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    Button {
                        Haptics.tick()
                        withAnimation(Theme.snappy) { row.add() }
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = row.icon {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "square.2.layers.3d").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
                            }
                            Text(verbatim: row.title).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PickerRowStyle())
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: rows.count <= 8)
    }
}
