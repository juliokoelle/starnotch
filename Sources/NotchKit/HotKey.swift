import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's `RegisterEventHotKey`.
/// Works without Accessibility permission, unlike a global key event monitor.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// The keys came up again (hold-to-talk); nil for shortcuts that only press.
    private let release: (() -> Void)?

    /// Control + Option + Space.
    static func controlOptionSpace(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), id: 1, action: action)
    }

    /// Control + Option + J: join the next meeting.
    static func controlOptionJ(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey), id: 2, action: action)
    }

    /// Control + Option + N: quick capture (design preview).
    static func controlOptionN(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), id: 3, action: action)
    }

    /// Control + Option + W: Watch mode on or off.
    static func controlOptionW(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey), id: 4, action: action)
    }

    /// Control + Option + I: open the quick-capture inbox.
    /// Control + Option + V: the clipboard history.
    static func controlOptionV(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), id: 6, action: action)
    }

    static func controlOptionI(action: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey), id: 5, action: action)
    }

    /// Control + Option + T: ask Tara; held, she listens until the keys come up.
    static func controlOptionT(action: @escaping () -> Void, release: @escaping () -> Void) -> HotKey {
        HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), id: 7, action: action, release: release)
    }

    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void, release: (() -> Void)? = nil) {
        self.action = action
        self.release = release
        self.id = id

        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        if release != nil {
            eventTypes.append(EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            // Every handler sees every hot key of the app; act only on our own id.
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated {
                if released { hotKey.release?() } else { hotKey.action() }
            }
            return noErr
        }, eventTypes.count, &eventTypes, context, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E_53_57_54), id: id)  // "NSWT"
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr || registered != noErr {
            Log.app.error("Hot key registration failed (\(status), \(registered))")
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
