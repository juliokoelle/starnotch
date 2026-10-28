import AppKit

/// Cut, copy, paste, select all, undo and redo in every text field (Ask Tara, quick capture, the
/// palette, the notepad, Settings). AppKit finds these keys in the main menu; an accessory app has
/// none, so ⌘V did nothing and Wispr Flow's paste (a ⌘V) got lost. An accessory app never shows
/// its menu bar, so this menu only carries the keys.
@MainActor
enum EditMenu {
    static func install() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(NSMenuItem())  // the first item is the app's own menu
        let item = NSMenuItem()
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
