@preconcurrency import AVFoundation
import Foundation
import NotchCore
@preconcurrency import Speech

/// The teleprompter's ears: the microphone into Apple's speech recognition on this Mac, live, in
/// the script's language. Nothing is recorded or kept and no audio leaves the Mac. On macOS 26 and
/// later it is SpeechTranscriber (made for long, live speech; Apple's model for the language is
/// fetched once); before that, or without that model, SFSpeechRecognizer where it runs on the Mac
/// for the language. Never the server-based recognition: without either, the band scrolls at a
/// constant speed instead.
@MainActor
final class PrompterListener {
    enum State: Equatable {
        case idle
        /// The microphone, or Apple's speech model for the language, getting ready.
        case preparing
        case listening
        case unavailable(Problem)
    }

    enum Problem: Equatable {
        /// Microphone or speech recognition switched off for the app in System Settings.
        case denied
        /// No recognition on this Mac for the language.
        case language
        case microphone
        /// Recognition kept stopping.
        case failed
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { onState?(state) } }
    }
    /// The running transcript and its session: each recognition that starts afresh is a new one.
    var onHeard: ((String, Int) -> Void)?
    var onState: ((State) -> Void)?

    private var engine: AVAudioEngine?
    /// Bumped by every start and stop, so late answers of an earlier start change nothing.
    private var generation = 0
    private var session = 0
    // SFSpeechRecognizer
    private var recognizer: SFSpeechRecognizer?
    private var requests: RequestSlot?
    private var task: SFSpeechRecognitionTask?
    private var hints: [String] = []
    private var restarts: [Date] = []
    // SpeechTranscriber (macOS 26)
    private var analyzerStop: (() -> Void)?

    var isActive: Bool { state == .preparing || state == .listening }

    /// Listens in `language`; `hints` are the script's rarer words, so names come out right.
    /// Asks for the microphone (and, before macOS 26, speech recognition) the first time.
    func start(language: PrompterLanguage, hints: [String]) {
        stop()
        let generation = self.generation
        self.hints = Array(hints.prefix(100))
        state = .preparing
        Task { [weak self] in
            if #available(macOS 26, *), let transcriber = await Self.transcriber(for: language) {
                guard await Self.microphoneAllowed() else {
                    self?.fail(.denied, generation)
                    return
                }
                if await self?.startAnalyzer(transcriber, generation: generation) ?? true { return }
            }
            guard await Self.speechAllowed(), await Self.microphoneAllowed() else {
                self?.fail(.denied, generation)
                return
            }
            self?.startRecognizer(language, generation: generation)
        }
    }

    func stop() {
        generation += 1
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        requests?.end()
        requests = nil
        task?.cancel()
        task = nil
        recognizer = nil
        analyzerStop?()
        analyzerStop = nil
        restarts = []
        if isActive { state = .idle }
    }

    private func fail(_ problem: Problem, _ generation: Int) {
        guard generation == self.generation else { return }
        stop()
        state = .unavailable(problem)
    }

    /// The user's own variant of the language when they use one (en-GB, de-AT), else the main one.
    static func locale(for language: PrompterLanguage) -> Locale {
        let own = Locale.preferredLanguages.first { $0.hasPrefix(language.rawValue + "-") }
        return Locale(identifier: own ?? (language == .de ? "de-DE" : "en-US"))
    }

    // MARK: Permissions (asked from the user's click that started reading)

    // Nonisolated: macOS answers on its own queues.
    nonisolated private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    // MARK: SpeechTranscriber

    /// A transcriber for the language when this Mac has one (or can fetch its model).
    @available(macOS 26, *)
    private static func transcriber(for language: PrompterLanguage) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale(for: language)) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [transcriber]) == .unsupported ? nil : transcriber
    }

    /// False when it couldn't start here (the recognizer is tried next); true when it runs, failed
    /// for good, or was stopped meanwhile.
    @available(macOS 26, *)
    private func startAnalyzer(_ transcriber: SpeechTranscriber, generation: Int) async -> Bool {
        do {
            if await AssetInventory.status(forModules: [transcriber]) != .installed {
                try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            }
            guard generation == self.generation else { return true }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return false }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !hints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = hints
                try? await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(64))
            try await analyzer.start(inputSequence: stream)
            let finish = {
                input.finish()
                Task { await analyzer.cancelAndFinishNow() }
            }
            guard generation == self.generation else {
                finish()
                return true
            }
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let microphone = node.outputFormat(forBus: 0)
            guard microphone.sampleRate > 0, microphone.channelCount > 0,
                  let converter = Converter(from: microphone, to: format) else {
                finish()
                fail(.microphone, generation)
                return true
            }
            node.installTap(onBus: 0, bufferSize: 4096, format: microphone, block: Self.analyzerTap(converter, into: input))
            engine.prepare()
            do {
                try engine.start()
            } catch {
                node.removeTap(onBus: 0)
                finish()
                fail(.microphone, generation)
                return true
            }
            session += 1
            let session = self.session
            // Finished text stays; the volatile rest of the sentence is replaced as it firms up.
            let results = Task { [weak self] in
                var final = ""
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal { final += text }
                        guard let self, generation == self.generation else { return }
                        self.onHeard?(result.isFinal ? final : final + text, session)
                    }
                } catch {
                    Log.app.error("Teleprompter transcriber: \(error.localizedDescription, privacy: .public)")
                }
                self?.fail(.failed, generation)
            }
            self.engine = engine
            analyzerStop = {
                results.cancel()
                finish()
            }
            state = .listening
            return true
        } catch {
            Log.app.error("Teleprompter transcriber unavailable: \(error.localizedDescription, privacy: .public)")
            return generation != self.generation
        }
    }

    @available(macOS 26, *)
    nonisolated private static func analyzerTap(_ converter: Converter,
                                                into input: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    // MARK: SFSpeechRecognizer

    private func startRecognizer(_ language: PrompterLanguage, generation: Int) {
        guard generation == self.generation else { return }
        // On the Mac only: a language without on-device recognition isn't listened to at all.
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale(for: language)), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            fail(.language, generation)
            return
        }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail(.microphone, generation)
            return
        }
        let requests = RequestSlot()
        node.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.recognizerTap(requests))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            fail(.microphone, generation)
            return
        }
        self.engine = engine
        self.recognizer = recognizer
        self.requests = requests
        beginTask(generation)
        state = .listening
    }

    /// One recognition; when it ends by itself (a long pause, its time limit) the next one starts
    /// on the same microphone, unless that keeps happening at once.
    private func beginTask(_ generation: Int) {
        guard generation == self.generation, let recognizer, let requests else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = hints
        requests.set(request)
        session += 1
        let session = self.session
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, ended in
            guard let self, generation == self.generation else { return }
            if let text { self.onHeard?(text, session) }
            guard ended else { return }
            let now = Date()
            self.restarts = self.restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
            if self.restarts.count > 4 {
                self.fail(.failed, generation)
            } else {
                self.beginTask(generation)
            }
        })
    }

    // Built outside the main actor: the audio thread and the recognizer call these.

    nonisolated private static func recognizerTap(_ requests: RequestSlot) -> AVAudioNodeTapBlock {
        { buffer, _ in requests.append(buffer) }
    }

    nonisolated private static func handler(_ done: @escaping @MainActor @Sendable (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in done(text, ended) }
        }
    }
}

/// The request the microphone feeds; swapped when a recognition ends and the next begins.
private final class RequestSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func end() {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }
}

/// The microphone's buffers in the analyzer's format (a copy each, since the engine reuses its
/// buffers). Used on the audio thread only.
private final class Converter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let fed = Fed()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if fed.done {
                status.pointee = .noDataNow
                return nil
            }
            fed.done = true
            status.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    private final class Fed: @unchecked Sendable {
        var done = false
    }
}
