import Foundation
import Testing
@testable import NotchCore

/// The mask's newer rules: more key shapes, labels in more languages, pages that are never read and
/// the net for keys of unknown shapes. Every key here is made up, and keys in a provider's shape are
/// put together at runtime, so no secret scanner mistakes this file for a leak.
@Suite struct ScreenMaskShapeTests {
    private func masked(_ text: String) -> String { ScreenMask.mask(text).text }
    private func repeated(_ part: String, _ count: Int) -> String { String(repeating: part, count: count) }

    // MARK: Prefixes

    @Test func aBrevoKeyOnAGermanSettingsPage() {
        let key = "xkeysib-" + repeated("0123456789abcdef", 4) + "-" + "q1w2e3r4t5y6u7i8"
        #expect(masked("API-Schlüssel: \(key)") == "API-Schlüssel: [key]")
        #expect(masked("Ihr API-Schlüssel\n\(key)\nKopieren") == "Ihr API-Schlüssel\n[key]\nKopieren")
        #expect(masked(key) == "[key]")
        #expect(masked("SMTP: " + "xsmtpsib-" + repeated("fedcba9876543210", 4) + "-" + "Q1W2E3R4T5Y6U7I8") == "SMTP: [key]")
    }

    @Test func morePrefixesInTheirProvidersShapes() {
        let keys = [
            "sb_secret_" + repeated("Ab3_x", 6) + "Z",
            "sbp_" + repeated("0a1b2c3d", 5),
            "whsec_" + repeated("Ab3Cd4", 6),
            "re_" + "Ab3Cd4Ef" + "_" + repeated("Gh5Jk6", 4),
            "gsk_" + repeated("Ab3Cd4", 9),
            "xai-" + repeated("Ab3Cd4Ef5G", 8),
            "r8_" + repeated("Ab3Cd4", 6) + "E",
            "GOCSPX-" + repeated("Ab3Cd4", 4) + "Ef5G",
            "lsv2_pt_" + repeated("0a1b2c3d", 4) + "_" + "0a1b2c3d4e",
            "sk_" + repeated("0a1b2c3d", 6),
            "sk-or-v1-" + repeated("0a1b2c3d", 8),
        ]
        for key in keys {
            #expect(masked("KEY \(key) end") == "KEY [key] end", "\(key.prefix(8))")
        }
    }

    @Test func publicKeysAndLookalikesStay() {
        // Supabase's publishable key is public by design.
        let publishable = "sb_publishable_" + repeated("Ab3Cd4", 5) + "E"
        #expect(masked(publishable) == publishable)
        // A snake_case name in Resend's shape, a model name after xAI's prefix, short tails.
        // The Resend lookalike is joined at run time: GitHub's push protection takes it for a key.
        for text in ["re_" + "abcdefgh_ijkmnopqrstuvwxyzabcdefg", "xai-grok-4-fast", "gsk_short", "whsec_test", "sb_secret_demo"] {
            #expect(masked(text) == text)
        }
    }

    // MARK: Labels

    @Test func labelsInGermanAndMoreLanguages() {
        let value = "q1w2e3r4t5y6u7i8"
        #expect(masked("Zugangsschlüssel: \(value)") == "Zugangsschlüssel: [key]")
        #expect(masked("Geheimnis = \(value)") == "Geheimnis = [key]")
        #expect(masked("DatenbankPasswort: \(value)") == "DatenbankPasswort: [key]")
        #expect(masked("Zugangsdaten: \(value)") == "Zugangsdaten: [key]")
        #expect(masked("Clé API : \(value)") == "Clé API : [key]")
        #expect(masked("clave secreta: \(value)") == "clave secreta: [key]")
        #expect(masked("API-sleutel: \(value)") == "API-sleutel: [key]")
        #expect(masked("Zugangsschlüssel\n\(value)") == "Zugangsschlüssel\n[key]")
    }

    @Test func germanLabelWordsWithoutASecretStay() {
        // Only a value with letters and digits mixed is masked after these labels.
        for text in ["Schlüssel: Haustür", "Zugangspasswort: vergessen", "Geheimnis: Vertrauen ist wichtig", "Passwort vergessen?",
                     "Schlüsselübergabe am Freitag", "Token: abgelaufen", "API-Schlüssel erstellen"] {
            #expect(masked(text) == text)
        }
    }

    // MARK: Pages never read

    @Test func keyPagesAreKnownByTheirAddress() {
        for url in ["https://github.com/settings/tokens", "https://github.com/settings/personal-access-tokens/new",
                    "https://console.anthropic.com/settings/keys", "https://platform.openai.com/api-keys",
                    "https://app.brevo.com/settings/keys/api", "https://supabase.com/dashboard/project/abcdefghijklmnopqrst/settings/api",
                    "https://supabase.com/dashboard/project/abcdefghijklmnopqrst/settings/api-keys", "https://dashboard.stripe.com/test/apikeys",
                    "https://vercel.com/account/tokens", "https://dash.cloudflare.com/profile/api-tokens",
                    "https://console.aws.amazon.com/iam/home#/security_credentials", "https://console.cloud.google.com/apis/credentials?project=demo",
                    "https://aistudio.google.com/apikey", "https://app.netlify.com/user/applications#personal-access-tokens",
                    "https://example.com/account/security/two-factor", "HTTPS://EXAMPLE.COM/API-KEYS"] {
            #expect(ScreenMask.isKeyPage(url), "\(url)")
        }
    }

    @Test func pagesAboutKeysAreStillRead() {
        for url in ["https://github.com/apple/swift/blob/main/docs/tokens.md", "https://en.wikipedia.org/wiki/Security_token",
                    "https://docs.python.org/3/library/stdtypes.html#dict.keys", "https://example.com/blog/how-to-rotate-api-keys",
                    "https://www.notion.so/Keys-to-success-4f2a", "https://example.com/settings/apis-overview",
                    "https://github.com/settings/security", "file:///tmp/settings/keys", "not a url", ""] {
            #expect(!ScreenMask.isKeyPage(url), "\(url)")
        }
    }

    // MARK: The net for unknown shapes

    @Test func theNetCatchesKeysOfUnknownShapes() {
        // Small letters and digits (the shape Brevo's key had), capitals and digits, base64url, hex, padding.
        for key in ["q8w7e6r5t4y3u2i1o0p9a8s7d6f5g4h3", "Q8W7E6R5T4Y3U2I1O0P9A8S7D6F5G4H3", "Zx9_Qw8-Er7Ty6Ui5Op4As3Df2Gh1Jk0L",
                    "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d", "q8w7e6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1=="] {
            #expect(masked("value \(key) here") == "value [key] here", "\(key)")
        }
        // Only the random part of a URL goes.
        #expect(masked("https://docs.google.com/document/d/1Ab2Cd3Ef4Gh5Ij6Kl7Mn8Op9Qr0St1Uv2Wx3Yz4Ab5C/edit")
                == "https://docs.google.com/document/d/[key]/edit")
        #expect(masked("https://example.com/callback?state=q8w7e6r5t4y3u2i1o0p9a8s7d6f5g4h3&lang=de")
                == "https://example.com/callback?state=[key]&lang=de")
    }

    @Test func theNetLeavesOrdinaryTextAlone() {
        for text in [
            "Merged 3f2a9c1e5b7d9f0a1c3e5b7d9f0a1c3e5b7d9f0a into main",
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "Request 123e4567-e89b-12d3-a456-426614174000 failed",
            "https://example.com/blog/how-to-build-a-notch-app-in-swift-and-swiftui-2026",
            "git switch feature/screen-mask-layers-for-starnotch-2026",
            "MAX_RETRY_COUNT_FOR_UPLOAD_2026_V2_AND_MORE_SETTINGS = 3",
            "iPhone15ProScreenRecording20261104.mov",
            "IMG_20261104_142311_HDR_Portrait_Mode_v2_final.jpg",
            "Starnotch-2.14.0-beta.3+build.20261104-universal.dmg",
            "release-notes-version-2-3-4-build-20261104-final",
            "test_case_42_handles_unicode_in_file_names_correctly",
            "aaaaaaaaaaaaaaaa1111111111111111aaaa",
        ] {
            #expect(masked(text) == text, "\(text)")
        }
    }

    @Test func entropyAndSwitches() {
        #expect(ScreenMask.entropy("aaaa") == 0)
        #expect(abs(ScreenMask.entropy("abcd") - 2) < 0.0001)
        #expect(ScreenMask.switchRate("abc-def") == 0)
        #expect(ScreenMask.switchRate("a1b2") == 1)
        #expect(ScreenMask.switchRate("aB") == 1 && ScreenMask.switchRate("Ab") == 0)
    }
}

/// Keys the Mac already holds: masked whatever their shape, kept only as salted hashes.
@Suite struct ScreenMaskKnownKeysTests {
    // Values no other rule would catch.
    let value = "plain-looking-demo-value"
    let password = "Sommerwiese!"

    private func masked(_ text: String, _ known: KnownSecrets) -> String { ScreenMask.mask(text, known: known).text }

    @Test func aKnownKeyIsMaskedWhateverItsShape() {
        let known = KnownSecrets([value, password])
        #expect(masked("token \(value) here", known) == "token [key] here")
        #expect(masked("DEMO=\"\(value)\";", known) == "DEMO=\"[key]\";")
        #expect(masked("(\(value)), then", known) == "([key]), then")
        #expect(masked("It was \(password).", known) == "It was [key].")
        #expect(masked("\(value)\n\(value)", known) == "[key]\n[key]")
        #expect(ScreenMask.mask("a \(value) b \(password)", known: known).counts == [.key: 2])
        #expect(masked(value, KnownSecrets()) == value)
    }

    @Test func partsAndLongerWordsStay() {
        let known = KnownSecrets([value])
        for text in ["plain-looking-demo", "\(value)2", "x\(value)", "plain looking demo value"] {
            #expect(masked(text, known) == text)
        }
    }

    @Test func onlySaltedHashesAreKept() {
        let known = KnownSecrets([value])
        var dumped = ""
        dump(known, to: &dumped)
        #expect(!dumped.contains(value) && !String(reflecting: known).contains(value))
        #expect(known.contains(value) && !known.contains("plain-looking-demo-valuf"))
        // A new salt for every set: the same value hashes differently.
        #expect(KnownSecrets([value]).hashes.isDisjoint(with: known.hashes))
    }

    @Test func shortValuesShellExpressionsAndPathsAreNotLearnt() {
        #expect(KnownSecrets(["short", "two words here", "$(gh auth token)", "${HOME}/demo", "`cat demo`", "/tmp/demo/key-file",
                              "~/demo/key-file", ""]).isEmpty)
        #expect(KnownSecrets([value, value]).count == 1)
    }

    @Test func exportsFromAShellStartupFile() {
        let zshrc = """
            # keys
            export DEMO_API_KEY="quoted-demo-value-1"
            export DEMO_TOKEN='single-quoted-demo-2'
              export DEMO_SECRET=bare-demo-value-3 # a comment
            export demo_password=bare-demo-value-4;
            export GITHUB_TOKEN=$(gh auth token)
            export PATH="$PATH:/opt/homebrew/bin"
            DEMO_KEY=not-exported-value
            export DEMO_KEYS=wrong-suffix-value
            alias demo='export DEMO_KEY=inside-an-alias'
            """
        #expect(KnownSecrets.shellExports(zshrc).filter(KnownSecrets.worthLearning)
                == ["quoted-demo-value-1", "single-quoted-demo-2", "bare-demo-value-3", "bare-demo-value-4"])
    }

    @Test func storedItemsGiveEveryStringInside() {
        #expect(KnownSecrets.values(stored: "plain-stored-value") == ["plain-stored-value"])
        let token = #"{"access":"demo-access-token-1","refresh":"demo-refresh-token-2","expires":1800000000}"#
        #expect(Set(KnownSecrets.values(stored: token)) == ["demo-access-token-1", "demo-refresh-token-2"])
    }

    @Test func theSetInUseIsWhatTheMaskTakesByDefault() {
        let unique = "default-set-demo-value-7f3k"
        let before = KnownSecrets.current
        defer { KnownSecrets.current = before }
        KnownSecrets.current = KnownSecrets([unique])
        #expect(ScreenMask.mask("it is \(unique)").text == "it is [key]")
    }
}

/// gitleaks' rules (ScreenMaskGitleaks.swift, generated by scripts/gitleaks/convert.py): they compile,
/// run only with their keyword, mask the secret group, and a full screen stays fast.
@Suite struct ScreenMaskGitleaksTests {
    private func masked(_ text: String) -> String { ScreenMask.mask(text, known: KnownSecrets()).text }
    private let random48 = "q8w7e6r5t4y3u2i1o0p9a8s7d6f5g4h3j2k1l0z9x8c7v6b5"
    private let hex16 = "0a1b2c3d4e5f6789"

    @Test func everyGeneratedRuleCompiles() {
        let rules = ScreenMask.gitleaksRules
        #expect(rules.count > 150)
        #expect(ScreenMask.upstream.count == rules.count)
        #expect(Set(rules.map(\.id)).count == rules.count)
        #expect(rules.allSatisfy { !$0.keywords.isEmpty && $0.keywords.allSatisfy { $0 == $0.lowercased() } })
        #expect(!rules.contains { $0.id == "generic-api-key" })
    }

    @Test func shapesOnlyGitleaksKnowsAreMasked() {
        let keys = [
            "perplexity-api-key": "pplx-" + random48,
            "notion-api-token": "ntn_" + "48291037465" + random48.prefix(35),
            "linear-api-key": "lin_api_" + random48.prefix(40),
            "digitalocean-pat": "dop_v1_" + String(repeating: hex16, count: 4),
            "shopify-access-token": "shpat_" + String(repeating: hex16, count: 2),
            "postman-api-token": "PMAK-" + hex16 + "0a1b2c3d" + "-" + String(repeating: hex16, count: 2) + "0a",
            "jwt-base64": "ZXlKaGJHY2lPaU" + random48,
        ]
        for (id, key) in keys {
            #expect(ScreenMask.upstream(for: key).contains { $0.rule.id == id }, "\(id)")
            #expect(masked("found \(key) here") == "found [key] here", "\(id)")
        }
    }

    @Test func aRuleRunsOnlyWithItsKeyword() {
        #expect(ScreenMask.upstream(for: "Lena wants the pricing deck by Friday.").isEmpty)
        #expect(ScreenMask.upstream(for: "PPLX- in capitals").contains { $0.rule.id == "perplexity-api-key" })
    }

    @Test func theSecretGroupGoesAndAValueTooPlainStays() {
        #expect(masked("ADAFRUIT_IO = " + random48.prefix(32)) == "ADAFRUIT_IO = [key]")
        // Linear's rule asks for more entropy than forty times the same letter.
        let plain = "lin_api_" + String(repeating: "a", count: 40)
        #expect(masked(plain) == plain)
    }

    @Test func aFullScreenIsMaskedFast() {
        let lines = [
            "Lena wants the pricing deck by Friday; Max reviews the onboarding copy at 14:30.",
            "let apiKey = config.value(forKey: \"token\") // auth check before the secret store",
            "curl -H \"Authorization: Bearer $TOKEN\" https://api.example.com/v1/keys?limit=20",
            "Merged 3f2a9c1e5b7d9f0a1c3e5b7d9f0a1c3e5b7d9f0a into main, see the access log",
            "export DATABASE_URL=postgres://localhost:5432/app  # credentials in the keychain",
            "The quick brown fox asks the desk clerk for a task list, then a key to room 12.",
            "Sonar, Slack, Stripe, GitHub, GitLab, Heroku, Twilio, SendGrid and Discord notes.",
        ]
        // About what a window gives at most: 400 lines, some 34,000 characters.
        let text = (0..<400).map { lines[$0 % lines.count] + " #\($0)" }.joined(separator: "\n")
        _ = masked(text)  // the regexes compile on first use
        let clock = ContinuousClock()
        let slowest = (0..<3).map { _ in clock.measure { _ = masked(text) } }.max() ?? .zero
        // About 0.1 s in a debug build on an M-series Mac; a slow CI runner gets ten times that.
        #expect(slowest < .seconds(1))
    }
}
