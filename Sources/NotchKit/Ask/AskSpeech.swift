@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Speaking to Tara: the microphone into Apple's speech recognition, on the Mac itself when the
/// language supports it, in the interface language (German or English). macOS asks for speech
/// recognition and the microphone the first time.
@MainActor
final class AskSpeech {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRunning = false

    /// German when the app speaks German, else English.
    static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first == "de" ? "de-DE" : "en-US")
    }

    /// Asks for speech recognition, then the microphone (each only the first time); true when both are allowed.
    static func authorize(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                Task { @MainActor in done(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in done(granted) }
            }
        }
    }

    /// Both already allowed, so starting asks nothing.
    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var isDenied: Bool {
        SFSpeechRecognizer.authorizationStatus() == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    /// Starts listening; `onText` gets the words so far, `onEnd` when recognition stops by itself.
    /// False when there is no recognizer for the language or no microphone.
    func start(onText: @escaping @MainActor @Sendable (String) -> Void,
               onEnd: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard !isRunning, let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On the Mac when it can; otherwise Apple's servers, as the system dictation does.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler(onText: onText, onEnd: onEnd))
        isRunning = true
        return true
    }

    /// Stops the microphone; the last words still arrive through `onText`.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }

    /// Stops and drops what wasn't recognized yet.
    func cancel() {
        stop()
        task?.cancel()
        task = nil
    }

    // Built outside the main actor: the audio thread and the recognizer call these.

    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func handler(onText: @escaping @MainActor @Sendable (String) -> Void,
                                            onEnd: @escaping @MainActor @Sendable () -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                if let text { onText(text) }
                if ended { onEnd() }
            }
        }
    }
}
