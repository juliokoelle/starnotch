import AppKit
import NotchCore
import SwiftUI

/// `--preview pack-sheet:<character>[:<level>]`: every state of a character as the app draws it
/// (colorway, glow, sheen, idle life), on the island's card colour. For checking a pack.
@MainActor
enum PackSheet {
    private static var window: NSWindow?

    static func show(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        let id = parts.count > 1 ? parts[1] : (AvatarLibrary.shared.characters.first?.id ?? "")
        let level = parts.count > 2 ? PerformanceLevel(rawValue: parts[2]) : nil
        guard let character = AvatarLibrary.shared.character(id) else { return }
        let states = character.states.keys.sorted()
        let view = PackSheetView(character: id, name: character.name, level: level, states: states)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(character.name) states"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        Self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct PackSheetView: View {
    let character: String
    let name: String
    let level: PerformanceLevel?
    let states: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name)\(level.map { " · \($0.title)" } ?? "")").font(Theme.font(15, .semibold)).foregroundStyle(Theme.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 10), count: 5), spacing: 10) {
                ForEach(states, id: \.self) { state in
                    VStack(spacing: 6) {
                        AvatarView(character: character, mood: .idle, height: 84, emergeOnAppear: false,
                                   level: level, forcedState: state)
                            .frame(width: 110, height: 96, alignment: .bottom)
                        Text(state).font(Theme.font(11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 118, height: 128)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
