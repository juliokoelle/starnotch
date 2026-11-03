import Foundation
import Testing
@testable import NotchCore

/// The teleprompter: match keys, numbers, the script's words, following a speaker, the band's lines,
/// the recent scripts.
struct PrompterTests {
    static let english = """
    Good morning, everyone. Thank you for joining the quarterly review.

    Last quarter we shipped the new onboarding flow. Activation grew by 25 percent, and support tickets fell for the third month in a row.

    Our biggest risk is hiring. We have four open roles and only two candidates in the final round. If we don't close them by December, the mobile launch slips into 2027.

    [Slide 4]

    So here is what I'm asking for today: approve the budget for two contractors, and give the team one more sprint to finish the payments integration.

    Thank you. I'm happy to take questions.
    """

    /// The same, as a recognizer writes it: no punctuation, some numbers as words, some as digits.
    static let englishSpoken = """
    good morning everyone thank you for joining the quarterly review \
    last quarter we shipped the new onboarding flow activation grew by twenty five percent and support tickets fell for the third month in a row \
    our biggest risk is hiring we have 4 open roles and only 2 candidates in the final round if we don't close them by december the mobile launch slips into twenty twenty seven \
    so here is what I'm asking for today approve the budget for 2 contractors and give the team one more sprint to finish the payments integration \
    thank you I'm happy to take questions
    """

    static let german = """
    Guten Morgen zusammen. Danke, dass ihr heute dabei seid.

    Im letzten Quartal haben wir das neue Kundenfeedback-System eingeführt. Die Zufriedenheit ist um 25 Prozent gestiegen, und die Bearbeitungszeit ist auf drei Tage gefallen.

    Unser größtes Risiko bleibt die Straßenbahn-Kooperation mit der Stadt. Ohne Zusage bis zum 15. Dezember verschiebt sich der Start auf das Frühjahr 2027.

    Deshalb bitte ich euch heute um zwei Dinge: grünes Licht für das Budget und eine Woche mehr Zeit für die Abnahme.
    """

    /// Read with compounds split, ß as ss and the numbers spoken.
    static let germanSpoken = """
    guten morgen zusammen danke dass ihr heute dabei seid \
    im letzten quartal haben wir das neue kunden feedback system eingeführt die zufriedenheit ist um fünfundzwanzig prozent gestiegen und die bearbeitungszeit ist auf 3 tage gefallen \
    unser grösstes risiko bleibt die strassenbahn kooperation mit der stadt ohne zusage bis zum fünfzehnten dezember verschiebt sich der start auf das frühjahr zweitausendsiebenundzwanzig \
    deshalb bitte ich euch heute um 2 dinge grünes licht für das budget und eine woche mehr zeit für die abnahme
    """

    /// Feeds `spoken` a word at a time as a recognizer's growing transcript; the place after each word.
    @discardableResult
    private func speak(_ spoken: String, to follower: inout PrompterFollower, after transcript: inout String,
                       session: Int = 0) -> [Int] {
        var places: [Int] = []
        for word in spoken.split(whereSeparator: \.isWhitespace) {
            transcript += (transcript.isEmpty ? "" : " ") + word
            follower.hear(transcript, session: session)
            places.append(follower.position)
        }
        return places
    }

    private func follower(_ script: String = english, language: PrompterLanguage = .en) -> PrompterFollower {
        PrompterFollower(keys: PrompterText(script).keys, language: language)
    }

    /// The key index just after the first `phrase` in the script's keys (from `from`).
    private func after(_ phrase: String, in script: String = english, from: Int = 0) -> Int {
        let keys = PrompterText(script).keys
        let words = PrompterWords.keys(phrase)
        for start in from...(keys.count - words.count) where Array(keys[start..<start + words.count]) == words {
            return start + words.count
        }
        Issue.record("“\(phrase)” isn't in the script")
        return -1
    }

    private func isMonotonic(_ places: [Int]) -> Bool { zip(places, places.dropFirst()).allSatisfy { $0 <= $1 } }

    // MARK: Match keys

    @Test func keysFoldCaseAccentsAndPunctuation() {
        #expect(PrompterWords.keys("Don't stop — it's “state-of-the-art” E-Mail, Straße & Café!")
            == ["dont", "stop", "its", "state", "of", "the", "art", "e", "mail", "strasse", "cafe"])
        #expect(PrompterWords.keys("  ") == [])
        #expect(PrompterWords.keys("(Yes.) …") == ["yes"])
    }

    @Test func englishNumberWordsBecomeDigits() {
        #expect(PrompterWords.keys("twenty-five") == ["25"])
        #expect(PrompterWords.keys("one hundred and five people") == ["105", "people"])
        #expect(PrompterWords.keys("two thousand twenty six") == ["2026"])
        #expect(PrompterWords.keys("fifteen hundred") == ["1500"])
        #expect(PrompterWords.keys("5 million") == ["5000000"])
        #expect(PrompterWords.keys("1,000 or 1.000") == ["1000", "or", "1000"])
        #expect(PrompterWords.keys("3.5 and 3,5") == ["35", "and", "35"])
        #expect(PrompterWords.keys("at 10:30") == ["at", "1030"])
        // Words that can't continue a number start a new one.
        #expect(PrompterWords.keys("one two three") == ["1", "2", "3"])
        #expect(PrompterWords.keys("the one and only") == ["the", "1", "and", "only"])
        #expect(PrompterWords.keys("rock and roll") == ["rock", "and", "roll"])
        #expect(PrompterWords.keys("50% or fifty percent") == ["50", "%", "or", "50", "%"])
    }

    @Test func numbersTooLargeForAnIntStartANewOne() {
        // 10^19 doesn't fit in an Int: "billion" can't continue the number, and nothing crashes.
        #expect(PrompterWords.keys("10000000000 billion") == ["10000000000", "1000000000"])
        #expect(PrompterText("A market of 10,000,000,000 billion dollars.").keys == ["a", "market", "of", "10000000000", "1000000000", "dollars"])
        // Digits and words mixed, at Int.max (9223372036854775807) and one step past it.
        #expect(PrompterWords.keys("9223372036 billion eight hundred fifty four million seven hundred seventy five thousand eight hundred seven")
            == ["9223372036854775807"])
        #expect(PrompterWords.keys("9223372036 billion eight hundred fifty four million seven hundred seventy five thousand eight hundred nine")
            == ["9223372036854775800", "9"])
        #expect(PrompterWords.keys("9223372036 billion nine hundred million") == ["9223372036000000900", "1000000"])
        // Large, but it fits.
        #expect(PrompterWords.keys("9000000000 billion") == ["9000000000000000000"])
        #expect(PrompterWords.keys("999999999999999 thousand") == ["999999999999999000"])
    }

    @Test func germanNumberWordsBecomeDigits() {
        #expect(PrompterWords.keys("fünfundzwanzig") == ["25"])
        #expect(PrompterWords.keys("zweitausendsechsundzwanzig") == ["2026"])
        #expect(PrompterWords.keys("Einhundert und dreißig") == ["100", "und", "30"])
        #expect(PrompterWords.keys("zwei Millionen") == ["2000000"])
        #expect(PrompterWords.keys("25 Prozent") == ["25", "%"])
        #expect(PrompterWords.keys("elf Tage") == ["11", "tage"])
        #expect(PrompterWords.keys("null") == ["0"])
        // Articles and words that only contain a number stay words.
        #expect(PrompterWords.keys("ein Beispiel und eine Idee") == ["ein", "beispiel", "und", "eine", "idee"])
        #expect(PrompterWords.keys("Achtung Stunde Grund hunderte Tausende") == ["achtung", "stunde", "grund", "hunderte", "tausende"])
    }

    @Test func languageFollowsTheText() {
        #expect(PrompterLanguage.detect(Self.english) == .en)
        #expect(PrompterLanguage.detect(Self.german) == .de)
        #expect(PrompterLanguage.detect("Über Größe") == .de)
        #expect(PrompterLanguage.detect("") == .en)
        #expect(PrompterLanguage.detect("123", fallback: .de) == .de)
    }

    // MARK: The script

    @Test func scriptWordsParagraphsAndCues() {
        let text = PrompterText("Hello there.\n\n[Slide 2] Next, twenty five\nslides.")
        #expect(text.words.map(\.text) == ["Hello", "there.", "[Slide", "2]", "Next,", "twenty", "five", "slides."])
        #expect(text.words.map(\.paragraph) == [false, false, true, false, false, false, false, false])
        #expect(text.words.map(\.cue) == [false, false, true, true, false, false, false, false])
        // Cues are never expected to be spoken; the number is one key on its first word.
        #expect(text.keys == ["hello", "there", "next", "25", "slides"])
        #expect(text.keyWords == [0, 1, 4, 5, 7])
        #expect(text.word(atKey: 2) == 4)
        #expect(text.word(atKey: 5) == 8)
        #expect(text.key(atWord: 2) == 2)
        #expect(text.key(atWord: 6) == 4)
        #expect(text.key(atWord: 8) == 5)
        // An unclosed bracket ends with its paragraph.
        let open = PrompterText("[pause and\n\nthen go")
        #expect(open.keys == ["then", "go"])
    }

    @Test func markdownBecomesPlainScript() {
        let markdown = """
        ---
        title: Talk
        ---
        # Intro

        Hello **everyone**, see [our site](https://example.com) and [[Notes|the notes]].
        - First point
        - Second point
        <!-- private -->
        `code`
        """
        #expect(PrompterText.plain(markdown: markdown)
            == "Intro\n\nHello everyone, see our site and the notes.\n\nFirst point\n\nSecond point\n\ncode")
    }

    // MARK: Following

    @Test func followsAStraightReadingToTheEnd() {
        var follower = follower()
        var transcript = ""
        let places = speak(Self.englishSpoken, to: &follower, after: &transcript)
        #expect(isMonotonic(places))
        #expect(follower.isFinished)
        // It keeps up: never more than a few words behind the speaker.
        #expect(places[20] >= 17)
    }

    @Test func followsAGermanReadingWithCompoundsAndNumbers() {
        var follower = follower(Self.german, language: .de)
        var transcript = ""
        let places = speak(Self.germanSpoken, to: &follower, after: &transcript)
        #expect(isMonotonic(places))
        #expect(follower.isFinished)
    }

    @Test func toleratesMisheardWords() {
        // Every fifth word misheard as something else entirely, every seventh slightly off.
        let words = Self.englishSpoken.split(separator: " ").enumerated().map { index, word -> String in
            if index % 5 == 4 { return "blorp" }
            if index % 7 == 6, word.count >= 5 { return word.dropLast() + "s" }
            return String(word)
        }
        var follower = follower()
        var transcript = ""
        let places = speak(words.joined(separator: " "), to: &follower, after: &transcript)
        #expect(isMonotonic(places))
        #expect(follower.position >= follower.keys.count - 2)
    }

    @Test func staysThroughAnAdLibAndPicksUpAfter() {
        var follower = follower()
        var transcript = ""
        speak("good morning everyone thank you for joining the quarterly review last quarter we shipped the new onboarding flow",
              to: &follower, after: &transcript)
        let place = follower.position
        #expect(place == after("onboarding flow"))
        let adLib = speak("uh let me add something I forgot about our coffee machine downstairs", to: &follower, after: &transcript)
        #expect(adLib.allSatisfy { $0 == place })
        speak("activation grew by twenty five percent", to: &follower, after: &transcript)
        #expect(follower.position == after("25 percent"))
    }

    @Test func fillerWordsMoveItAtMostAWordOrTwo() {
        var follower = follower()
        var transcript = ""
        speak("our biggest risk is hiring", to: &follower, after: &transcript)
        let place = follower.position
        speak("um so yeah okay um", to: &follower, after: &transcript)
        #expect(follower.position >= place && follower.position <= place + 2)
    }

    @Test func recoversWhenASentenceIsSkipped() {
        var follower = follower()
        var transcript = ""
        speak("last quarter we shipped the new onboarding flow", to: &follower, after: &transcript)
        // Skips "Activation grew … in a row." and goes on with the next paragraph.
        let places = speak("our biggest risk is hiring", to: &follower, after: &transcript)
        #expect(places[2] == after("our biggest risk"))
        #expect(follower.position == after("risk is hiring"))
    }

    @Test func findsASkippedPassageFarAhead() {
        let script = (0..<400).map { "term\($0)" }.enumerated()
            .map { $0.offset % 40 == 39 ? $0.element + "\n\n" : $0.element }.joined(separator: " ")
        var follower = PrompterFollower(keys: PrompterText(script).keys, language: .en)
        var transcript = ""
        speak((0..<20).map { "term\($0)" }.joined(separator: " "), to: &follower, after: &transcript)
        #expect(follower.position == 20)
        let places = speak((200..<206).map { "term\($0)" }.joined(separator: " "), to: &follower, after: &transcript)
        #expect(places[1] == 20)  // two words are not enough to jump that far
        #expect(follower.position == 206)
    }

    @Test func aRestartedSentenceDoesNotPullItBack() {
        var follower = follower()
        var transcript = ""
        speak("our biggest risk is hiring we have 4 open roles", to: &follower, after: &transcript)
        let place = follower.position
        let restart = speak("we have 4", to: &follower, after: &transcript)
        #expect(restart.allSatisfy { $0 >= place })
        speak("open roles and only two candidates", to: &follower, after: &transcript)
        #expect(follower.position == after("only two candidates"))
    }

    @Test func aPassageReadAgainMovesItBack() {
        var follower = follower()
        var transcript = ""
        speak("good morning everyone thank you for joining the quarterly review last quarter we shipped the new onboarding flow activation grew by 25 percent and support tickets fell for the third month in a row",
              to: &follower, after: &transcript)
        let end = follower.position
        #expect(end == after("in a row"))
        // The speaker goes back and reads the paragraph's first sentence again.
        speak("last quarter we shipped the new onboarding flow", to: &follower, after: &transcript)
        #expect(follower.position == after("onboarding flow"))
        #expect(follower.position < end)
    }

    @Test func neverMovesBackOnAFewEarlierWords() {
        var follower = follower()
        var transcript = ""
        speak("our biggest risk is hiring we have 4 open roles", to: &follower, after: &transcript)
        follower.jump(to: after("open roles"))
        let place = follower.position
        speak("thank you the quarterly", to: &follower, after: &transcript)
        #expect(follower.position >= place)
        #expect(follower.position <= place + 2)
    }

    @Test func followsThroughPunctuation() {
        let script = "\"Wait,\" she said — \"really?!\" (Yes.) It's 9:30, isn't it…"
        var follower = PrompterFollower(keys: PrompterText(script).keys, language: .en)
        var transcript = ""
        speak("wait she said really yes it's 930 isn't it", to: &follower, after: &transcript)
        #expect(follower.isFinished)
    }

    @Test func revisedTranscriptsNeverMoveItBack() {
        var follower = follower()
        var places: [Int] = []
        for transcript in ["Good", "Good morning", "Good morning every", "Good morning, every one", "Good morning, everyone.",
                           "Good morning, everyone. Thank", "Good morning, everyone. Thank you", "Good morning, everyone. Thank you."] {
            follower.hear(transcript)
            places.append(follower.position)
        }
        #expect(isMonotonic(places))
        #expect(follower.position == after("thank you"))
    }

    @Test func aJumpByHandSticks() {
        var follower = follower()
        var transcript = ""
        speak("good morning everyone thank you for joining the quarterly review", to: &follower, after: &transcript)
        // Forward by hand: the words said before can't pull it back.
        let risk = after("in a row")
        follower.jump(to: risk)
        follower.hear(transcript + " ")
        #expect(follower.position == risk)
        speak("our biggest risk", to: &follower, after: &transcript)
        #expect(follower.position == after("our biggest risk"))
        // Back by hand: nor can they pull it forward again.
        follower.jump(to: 0)
        speak("good morning", to: &follower, after: &transcript)
        #expect(follower.position == 2)
        // A new recognition session starts clean.
        follower.jump(to: 0)
        follower.hear("good morning everyone", session: 1)
        #expect(follower.position == 3)
        // Out of range clamps.
        follower.jump(to: 10_000)
        #expect(follower.isFinished)
        follower.jump(to: -4)
        #expect(follower.position == 0)
    }

    @Test func similarWordsAreNearMisses() {
        #expect(PrompterFollower.similar("quarterly", "quarterlys"))
        #expect(PrompterFollower.similar("hiring", "hirung"))
        #expect(!PrompterFollower.similar("numbers", "members"))
        #expect(!PrompterFollower.similar("cat", "car"))       // too short to guess
        #expect(!PrompterFollower.similar("2026", "2027"))     // numbers are exact
    }

    // MARK: Lines

    @Test func linesWrapAtTheWidthAndAtParagraphs() {
        let layout = PrompterLayout(widths: [10, 10, 10, 10, 10], paragraphs: [false, false, false, true, false],
                                    space: 2, width: 33, lineHeight: 20, paragraphGap: 8)
        #expect(layout.lines.map(\.words) == [0..<2, 2..<3, 3..<5])
        #expect(layout.lines.map(\.top) == [0, 20, 48])
        #expect(layout.height == 68)
        #expect(layout.line(ofWord: 2) == 1)
        #expect(layout.line(ofWord: 4) == 2)
        #expect(layout.line(ofWord: 5) == 2)   // the end of the script: the last line
        #expect(layout.line(atY: 0) == 0)
        #expect(layout.line(atY: 19) == 0)
        #expect(layout.line(atY: 20) == 1)
        #expect(layout.line(atY: 47) == 1)
        #expect(layout.line(atY: 48) == 2)
        #expect(layout.line(atY: 500) == 2)
        // A minute at 60 words is 5 words over 3 lines: 13.6 points a second.
        #expect(abs(layout.pointsPerSecond(wordsPerMinute: 60) - 13.6) < 0.01)
    }

    @Test func aWordWiderThanTheBandGetsItsOwnLine() {
        let layout = PrompterLayout(widths: [50, 5], paragraphs: [false, false], space: 2, width: 33, lineHeight: 20, paragraphGap: 8)
        #expect(layout.lines.map(\.words) == [0..<1, 1..<2])
        let empty = PrompterLayout(widths: [], paragraphs: [], space: 2, width: 33, lineHeight: 20, paragraphGap: 8)
        #expect(empty.lines.isEmpty)
        #expect(empty.height == 0)
        #expect(empty.line(ofWord: 0) == 0)
        #expect(empty.pointsPerSecond(wordsPerMinute: 130) == 0)
    }

    // MARK: Recent scripts and settings

    @Test func recentScriptsNewestFirstPrivateAndDeletable() throws {
        let library = PrompterLibrary(file: FileManager.default.temporaryDirectory
            .appending(path: "prompter-\(UUID().uuidString)/prompter-scripts.json"))
        let first = PrompterScript(text: "# Q3 Review\n\nGood morning.", now: Date(timeIntervalSince1970: 1_000))
        library.save(first)
        let second = PrompterScript(text: "Launch talk", now: Date(timeIntervalSince1970: 2_000))
        library.save(second)
        #expect(library.load().map(\.id) == [second.id, first.id])
        #expect(library.load().last?.title == "Q3 Review")
        // The same text again is the same script, back on top with its place.
        var reading = library.load()[1]
        reading.word = 7
        library.save(reading)
        let again = PrompterLibrary.script(for: "  # Q3 Review\n\nGood morning.\n", in: library.load(), now: Date(timeIntervalSince1970: 3_000))
        #expect(again.id == first.id)
        #expect(again.word == 7)
        #expect(library.save(again).map(\.id) == [first.id, second.id])
        let mode = try FileManager.default.attributesOfItem(atPath: library.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(library.delete(first.id).map(\.id) == [second.id])
        #expect(library.load().map(\.id) == [second.id])
        // At most `limit`, the oldest go.
        var many: [PrompterScript] = []
        for index in 0..<(PrompterLibrary.limit + 3) {
            many = PrompterLibrary.keeping(PrompterScript(text: "Script \(index)", now: Date(timeIntervalSince1970: Double(index))), in: many)
        }
        #expect(many.count == PrompterLibrary.limit)
        #expect(many.first?.text == "Script \(PrompterLibrary.limit + 2)")
    }

    @Test func titlesComeFromTheFirstLineOrTheFile() {
        #expect(PrompterScript.title(of: "\n\n## Kick-off: Q4 \n more") == "Kick-off: Q4")
        let long = PrompterScript.title(of: String(repeating: "word ", count: 30))
        #expect(long.count == 60 && long.hasSuffix("…"))
        #expect(PrompterScript(text: "Body text", title: "keynote").title == "keynote")
        #expect(PrompterScript(text: "Body text", title: "  ").title == "Body text")
        #expect(PrompterScript(text: Self.german).spokenLanguage == .de)
        var chosen = PrompterScript(text: Self.german)
        chosen.language = .en
        #expect(chosen.spokenLanguage == .en)
    }

    @Test func settingsStayInRangeAndDecodeTolerantly() throws {
        var settings = PrompterSettings(textSize: 36, lines: 5, wordsPerMinute: 220)
        settings.stepTextSize(1)
        settings.stepLines(1)
        settings.stepSpeed(1)
        #expect(settings == PrompterSettings(textSize: 30, lines: 5, wordsPerMinute: 220))
        settings.stepTextSize(-1)
        settings.stepLines(-1)
        settings.stepSpeed(-1)
        #expect(settings == PrompterSettings(textSize: 28, lines: 4, wordsPerMinute: 210))
        // Small by default, and a size saved under the old name starts over at it.
        #expect(PrompterSettings().textSize == 16)
        #expect(try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"textSize":26}"#.utf8)).textSize == 16)
        let decoded = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"constant","lines":9}"#.utf8))
        #expect(decoded == PrompterSettings(mode: .constant, lines: 5))
        #expect(try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"mode":"weird","textSize":"big"}"#.utf8)) == PrompterSettings())
    }
}
