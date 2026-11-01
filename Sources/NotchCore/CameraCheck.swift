/// Check camera before a call: a mirrored live preview in the meeting's card, beside Join. Which
/// card shows it, and what it shows; the app runs the camera exactly while `cameraOn` is true.
/// Nothing is recorded: the preview only shows what the camera sees.
public struct CameraCheck: Equatable, Sendable {
    /// What macOS allows, from `AVCaptureDevice.authorizationStatus(for: .video)`.
    public enum Access: Equatable, Sendable {
        case notAsked, allowed, denied

        /// `AVAuthorizationStatus`' raw value: 0 not determined, 1 restricted, 2 denied, 3 authorized.
        public init(status: Int) {
            switch status {
            case 0: self = .notAsked
            case 3: self = .allowed
            default: self = .denied
            }
        }
    }

    /// What the card shows under its header.
    public enum Card: Equatable, Sendable {
        case preview
        /// Camera access is off: what to switch on in System Settings.
        case accessOff
    }

    /// What a click asks of the app.
    public enum Step: Equatable, Sendable {
        /// Start the camera (the preview shows).
        case show
        /// Let macOS ask, then `answered`.
        case ask
        /// Access is off: open System Settings › Privacy & Security › Camera.
        case openSettings
        /// The check was open: it closes, the camera stops.
        case close
    }

    /// The meeting whose card shows the check.
    public private(set) var meetingID: String?
    public private(set) var card: Card?
    /// The meeting macOS is asking about; its answer only counts while the user waits for it.
    public private(set) var asking: String?

    public var cameraOn: Bool { card == .preview }

    public init() {}

    /// Check camera clicked on `meeting`'s card.
    public mutating func click(_ meeting: String, access: Access) -> Step {
        if meetingID == meeting, card != nil {
            close()
            return .close
        }
        switch access {
        case .allowed:
            show(.preview, for: meeting)
            return .show
        case .notAsked:
            asking = meeting
            return .ask
        case .denied:
            show(.accessOff, for: meeting)
            return .openSettings
        }
    }

    /// macOS's dialog was answered. Ignored once the card went away or the check closed meanwhile.
    public mutating func answered(_ meeting: String, granted: Bool) {
        guard asking == meeting else { return }
        show(granted ? .preview : .accessOff, for: meeting)
    }

    /// Closed with its button, Join, or the panel closing.
    public mutating func close() {
        meetingID = nil
        card = nil
        asking = nil
    }

    /// A card went away: only its own check closes, not one another card opened meanwhile.
    public mutating func left(_ meeting: String) {
        if meetingID == meeting || asking == meeting { close() }
    }

    private mutating func show(_ card: Card, for meeting: String) {
        meetingID = meeting
        self.card = card
        asking = nil
    }
}
