import NotchCore
import SwiftUI

/// The teleprompter band hanging from the notch: its controls beside the notch, the script (or
/// the choice of one) below, as close to the camera as the island goes.
struct PrompterView: View {
    let prompter: Prompter
    let notch: CGSize
    /// The island's width without its flares.
    let width: CGFloat
    let onClose: () -> Void

    var body: some View {
        let side = max(0, (width - notch.width) / 2)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PrompterLeading(prompter: prompter)
                    .padding(.leading, 12)
                    .frame(width: side, alignment: .leading)
                Color.clear.frame(width: notch.width)
                PrompterTrailing(prompter: prompter, onClose: onClose)
                    .padding(.trailing, 10)
                    .frame(width: side, alignment: .trailing)
            }
            .frame(height: notch.height)
            ZStack(alignment: .top) {
                switch prompter.phase {
                case .setup:
                    PrompterSetup(prompter: prompter).transition(.blurSlide(y: -6))
                case .reading:
                    PrompterReading(prompter: prompter).transition(.blurSlide(y: 6))
                }
            }
            .frame(width: width, height: prompter.bodyHeight, alignment: .top)
            .clipped()
        }
        .overlay {
            if prompter.dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .overlay {
                        Text("Let go to read it")
                            .font(Theme.font(13, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Color.black.opacity(0.85), in: Capsule())
                    }
                    .padding(EdgeInsets(top: notch.height + 2, leading: 6, bottom: 6, trailing: 6))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: prompter.dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { prompter.dropTargeted }, set: { prompter.dropTargeted = $0 })) { providers in
            FileDrop.load(providers) { prompter.drop($0) }
        }
        .onAppear { prompter.fit(width: width) }
        .onChange(of: width) { _, width in prompter.fit(width: width) }
    }
}

// MARK: - Beside the notch

/// Left of the notch: pause, voice or constant speed, and what listening does (or the speed).
private struct PrompterLeading: View {
    let prompter: Prompter

    var body: some View {
        switch prompter.phase {
        case .setup:
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold))
                Text("Teleprompter").font(Theme.font(12, .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        case .reading:
            HStack(spacing: 6) {
                BandButton(symbol: prompter.paused ? "play.fill" : "pause.fill",
                           help: prompter.paused ? "Go on (space)" : "Pause (space)") { prompter.togglePause() }
                ModeSwitch(prompter: prompter)
                if prompter.settings.mode == .voice {
                    status
                } else {
                    speed
                }
            }
            .lineLimit(1)
        }
    }

    private var finished: Bool { !prompter.text.words.isEmpty && prompter.word >= prompter.text.words.count }

    @ViewBuilder private var status: some View {
        let listening = prompter.listening == .listening && !prompter.paused
        HStack(spacing: 5) {
            ListeningGlyph(active: listening && prompter.hearing, size: 12,
                           tint: listening ? Theme.accent : Theme.textTertiary)
            Text(statusText)
                .font(Theme.font(11.5, .medium))
                .foregroundStyle(listening ? Theme.textSecondary : Theme.textTertiary)
                .fixedSize()
        }
        .help(Text("Follows your voice with Apple's recognition on this Mac. Nothing is recorded."))
    }

    private var statusText: LocalizedStringKey {
        if finished { return "The end" }
        if prompter.paused { return "Paused" }
        switch prompter.listening {
        case .preparing: return "Getting ready…"
        case .listening: return "Listening"
        case .unavailable: return "Can't listen"
        case .idle: return "Starting…"
        }
    }

    private var speed: some View {
        HStack(spacing: 0) {
            BandButton(symbol: "minus", help: "Slower (←)", size: 9.5) { prompter.stepSpeed(-1) }
                .disabled(prompter.settings.wordsPerMinute <= PrompterSettings.speeds.lowerBound)
            Text("\(prompter.settings.wordsPerMinute) wpm")
                .font(Theme.font(11.5, .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
                .fixedSize()
            BandButton(symbol: "plus", help: "Faster (→)", size: 9.5) { prompter.stepSpeed(1) }
                .disabled(prompter.settings.wordsPerMinute >= PrompterSettings.speeds.upperBound)
        }
        .help(Text("Words a minute at constant speed"))
    }
}

/// Follow my voice, or constant speed.
private struct ModeSwitch: View {
    let prompter: Prompter
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            option(.voice, symbol: "waveform", help: "Follow my voice")
            option(.constant, symbol: "speedometer", help: "Constant speed")
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func option(_ mode: PrompterSettings.Mode, symbol: String, help: LocalizedStringKey) -> some View {
        let selected = prompter.settings.mode == mode
        return Button {
            withAnimation(Theme.snappy) { prompter.setMode(mode) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 24, height: 18)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "mode", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Right of the notch: the language, type size, lines, the scripts, close.
private struct PrompterTrailing: View {
    let prompter: Prompter
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if prompter.phase == .reading {
                language
                BandButton(symbol: "textformat.size.smaller", help: "Smaller text (⌘−)") { prompter.stepTextSize(-1) }
                    .disabled(prompter.settings.textSize <= PrompterSettings.textSizes.lowerBound)
                BandButton(symbol: "textformat.size.larger", help: "Larger text (⌘+)") { prompter.stepTextSize(1) }
                    .disabled(prompter.settings.textSize >= PrompterSettings.textSizes.upperBound)
                BandButton(symbol: "line.3.horizontal", help: "Lines in the band: 3, 4 or 5") {
                    prompter.stepLines(prompter.settings.lines >= PrompterSettings.lineCounts.upperBound ? -2 : 1)
                }
                BandButton(symbol: "list.bullet", help: "Scripts") { prompter.showScripts() }
            } else if prompter.script != nil {
                BandButton(symbol: "chevron.backward", help: "Back to the script (esc)") { _ = prompter.backToReading() }
            }
            BandButton(symbol: "xmark", help: "Close (esc)", action: onClose)
        }
    }

    private var language: some View {
        let german = prompter.script?.spokenLanguage == .de
        return Button { prompter.toggleLanguage() } label: {
            Text(verbatim: german ? "DE" : "EN")
                .font(Theme.font(10, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 16)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(german ? Text("Listening in German. Click for English") : Text("Listening in English. Click for German"))
    }
}

/// A small icon button in the band's top row: a 24 pt target, brighter on hover.
private struct BandButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 11.5
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering && enabled ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(hovering && enabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Reading

/// The script in lines: the line being read bright, read words dimmed, what comes normal. The
/// text moves by transform only: a smooth slide to the next line when the voice gets there, a
/// steady glide at constant speed (a line at a time with Reduce Motion).
private struct PrompterReading: View {
    let prompter: Prompter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lineHeight = prompter.layout.lineHeight
        let visible = prompter.visibleHeight
        TimelineView(.animation(minimumInterval: nil, paused: prompter.rollingSince == nil)) { context in
            lines(at: context.date)
        }
        .frame(height: visible, alignment: .top)
        .clipped()
        .mask(fades(lineHeight))
        .overlay(alignment: .topLeading) {
            // The reading line's mark, fixed where the eyes rest.
            Capsule()
                .fill(prompter.paused ? Theme.textTertiary : Theme.accent)
                .frame(width: 3, height: (lineHeight * 0.56).rounded())
                .padding(.leading, prompter.columnInset - 13)
                .padding(.top, CGFloat(prompter.anchorLine) * lineHeight + (lineHeight * 0.22).rounded())
        }
        .padding(.top, Prompter.readingTop)
        .padding(.bottom, Prompter.readingBottom)
        .overlay(alignment: .bottom) {
            if let notice = prompter.notice {
                Text(verbatim: notice)
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Color(white: 0.13).opacity(0.96), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.blurSlide(y: 6))
            }
        }
        .animation(Theme.snappy, value: prompter.notice)
    }

    private func lines(at date: Date) -> some View {
        let layout = prompter.layout
        let y = displayed(at: date)
        let current = prompter.currentLine(at: date)
        let next = prompter.word(at: date)
        let lines = prompter.settings.lines
        let around = layout.line(atY: y)
        // The lines in view, with room on both sides for a slide of a few lines.
        let range = max(0, around - prompter.anchorLine - lines - 1)..<min(layout.lines.count, around + 2 * lines + 2)
        return ZStack(alignment: .topLeading) {
            ForEach(range, id: \.self) { index in
                let line = layout.lines[index]
                PrompterLine(words: Array(prompter.text.words[line.words]),
                             read: min(max(0, next - line.words.lowerBound), line.words.count),
                             current: index == current,
                             size: prompter.settings.textSize,
                             height: layout.lineHeight)
                    .equatable()
                    .offset(y: line.top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .offset(y: CGFloat(prompter.anchorLine) * layout.lineHeight - y)
        .padding(.horizontal, prompter.columnInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func displayed(at date: Date) -> CGFloat {
        let y = prompter.rolledScroll(at: date)
        let layout = prompter.layout
        guard prompter.rollingSince != nil, reduceMotion, !layout.lines.isEmpty else { return y }
        return layout.lines[layout.line(atY: y)].top
    }

    /// Soft edges: the read line above fades out, the last line fades into the island's edge.
    private func fades(_ lineHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(prompter.anchorLine > 0 ? 0.25 : 1), .black],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: (lineHeight * 0.5).rounded())
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: (lineHeight * 0.55).rounded())
        }
    }
}

/// One line of the script. Equatable, so only the line whose words change redraws while the
/// text moves.
private struct PrompterLine: View, Equatable {
    let words: [PrompterText.Word]
    /// How many of its words are read.
    let read: Int
    let current: Bool
    let size: Double
    let height: CGFloat

    var body: some View {
        var text = Text(verbatim: "")
        for (index, word) in words.enumerated() {
            let colour = word.cue || index < read ? Theme.textTertiary : current ? Theme.textPrimary : Theme.textBody.opacity(0.72)
            text = text + Text(verbatim: index == 0 ? word.text : " " + word.text).foregroundStyle(colour)
        }
        return text
            .font(.system(size: CGFloat(size), weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .frame(height: height, alignment: .leading)
    }
}

// MARK: - Setup

/// Choosing a script: paste, drop, or one of the recent ones (↑↓ ↵). Says once that the
/// audience never sees the band.
struct PrompterSetup: View {
    let prompter: Prompter

    static let rowHeight: CGFloat = 34
    static let visibleRows = 3

    /// The setup's height for `rows` recent scripts (at most three show, the rest scroll).
    static func height(rows: Int) -> CGFloat {
        let list = rows == 0 ? 64 : 18 + CGFloat(min(rows, visibleRows)) * rowHeight
        return 6 + 28 + 10 + list + 10 + 14 + 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Paste a script with ⌘V, or drop a .txt or .md file here")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Button { prompter.paste() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Theme.accent.opacity(0.9), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .help("Paste the script from the clipboard (⌘V)")
            }
            .frame(height: 28)
            if prompter.scripts.isEmpty {
                dropZone
            } else {
                recent
            }
            // What went wrong (an empty clipboard, a file it can't read) takes the line for a moment.
            Group {
                if let notice = prompter.notice {
                    Text(verbatim: notice).foregroundStyle(Theme.critical)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold))
                        Text("Hidden from screen sharing: your audience never sees the script")
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.font(11))
            .lineLimit(1)
            .frame(height: 14)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var dropZone: some View {
        VStack(spacing: 3) {
            Text("Drop a .txt or .md file").font(Theme.font(12.5, .medium)).foregroundStyle(Theme.textSecondary)
            Text("Recent scripts show here, kept only on this Mac").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textTertiary).frame(height: 14)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(prompter.scripts.enumerated()), id: \.element.id) { index, script in
                            row(script, selected: index == prompter.selected).id(script.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(min(prompter.scripts.count, Self.visibleRows)) * Self.rowHeight)
                .onChange(of: prompter.selected) { _, index in
                    guard prompter.scripts.indices.contains(index) else { return }
                    withAnimation(Theme.snappy) { proxy.scrollTo(prompter.scripts[index].id) }
                }
            }
        }
    }

    private func row(_ script: PrompterScript, selected: Bool) -> some View {
        let words = script.wordCount
        let minutes = max(1, Int((Double(words) / 130).rounded()))
        let started = script.word > 0 && script.word < words
        return ZStack(alignment: .trailing) {
            HoverRow(cornerRadius: 10, restOpacity: selected ? 0.07 : 0, help: Localization.string("Read this script")) {
                Haptics.confirm()
                prompter.read(script)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: script.title.isEmpty ? "…" : script.title)
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 4) {
                            Text("\(words) words · \(minutes) min")
                            if started { Text(verbatim: "·"); Text("goes on where you stopped") }
                        }
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 34)
                }
                .padding(.horizontal, 8)
                .frame(height: Self.rowHeight)
            }
            BandButton(symbol: "trash", help: "Delete", size: 10.5) { prompter.delete(script) }
                .padding(.trailing, 6)
        }
    }
}
