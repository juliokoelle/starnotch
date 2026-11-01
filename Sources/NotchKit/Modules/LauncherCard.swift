import AppKit
import NotchCore
import SwiftUI

/// Apple's `shortcuts` command line tool: the user's shortcuts by name, and running one. Both off
/// the main thread; nothing else of Shortcuts is touched.
enum ShortcutsTool {
    static let path = "/usr/bin/shortcuts"

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    /// The names `shortcuts list` prints, in its order.
    static func list() async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return Launcher.shortcutNames(from: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Runs a shortcut by its name; true when it finished without an error. A shortcut that asks
    /// for something shows its own window, and this waits for it.
    static func run(_ name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["run", name]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

/// The launcher in the Tools tab: the shortcuts and apps picked in Settings, three to a row. A
/// click runs a shortcut (its tile shows it running, then done or failed) or opens the app.
struct LauncherCard: View {
    let module: ToolsModule

    var body: some View {
        let items = module.launcherItems()
        NotchCard(padding: 6) {
            if items.isEmpty {
                empty
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 5)], spacing: 5) {
                        ForEach(items) { item in LauncherTile(module: module, item: item) }
                    }
                }
                // Three rows fit; more scroll, and the cut row fades.
                .scrollEdgeFade(bottom: items.count > 9 ? 10 : 0)
            }
        }
    }

    /// Centred like the empty clipboard: what goes here and where to pick it.
    private var empty: some View {
        VStack(spacing: 6) {
            Text("No shortcuts or apps yet").font(Theme.font(13, .semibold)).foregroundStyle(Theme.textPrimary)
            Text("Pick Apple Shortcuts and apps in Settings, then run them here with one click.")
                .font(Theme.font(12)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let open = module.openLauncherSettings {
                Button {
                    Haptics.tick()
                    open()
                } label: {
                    Label("Choose in Settings", systemImage: "gearshape")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(PressScale())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LauncherTile: View {
    let module: ToolsModule
    let item: LauncherItem

    var body: some View {
        let state = module.launchStates[item.id]
        HoverRow(cornerRadius: 9, restOpacity: 0.05, hoverOpacity: 0.1, help: help(state)) {
            module.launch(item)
        } label: {
            HStack(spacing: 8) {
                icon.frame(width: 22, height: 22)
                Text(verbatim: item.name)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                status(state)
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
        }
    }

    /// The app's own icon; a shortcut has Shortcuts' layers.
    @ViewBuilder private var icon: some View {
        if let app = item.app {
            Image(nsImage: AppIcons.icon(for: app, size: 44)).resizable().interpolation(.high)
        } else {
            Image(systemName: "square.2.layers.3d.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textBody)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder private func status(_ state: ToolsModule.LaunchState?) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.critical)
        case nil: EmptyView()
        }
    }

    private func help(_ state: ToolsModule.LaunchState?) -> String {
        switch state {
        case .running: String(format: Localization.string("Running “%@”…"), item.name)
        case .failed: String(format: Localization.string("“%@” stopped with an error"), item.name)
        case .done, nil: String(format: Localization.string(item.kind == .app ? "Open %@" : "Run “%@”"), item.name)
        }
    }
}
