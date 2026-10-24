# Contributing to Starnotch

Thanks for helping. A few things keep the app small, fast and easy to trust.

## Set up

You need macOS 14 or later and the Swift 6 toolchain. Xcode works; the Command Line Tools alone are enough.

```sh
./scripts/build-app.sh      # build/Starnotch.app, signed ad hoc
./scripts/test.sh           # unit tests (Swift Testing)
open build/Starnotch.app --args --sample-data   # test mode with made-up data
```

`scripts/test.sh` points the compiler at Swift Testing when only the Command Line Tools are installed. With Xcode, `swift test` works too.

## Where things go

- **`Sources/NotchCore`**: logic without AppKit (parsers, geometry, config, the connector API). Anything that can be tested belongs here, with a test in `Tests/NotchCoreTests`. Test files can't import Foundation on the Command Line Tools; use the helpers in `Tests/TestSupport`.
- **`Sources/NotchKit`**: the app. Modules implement `NotchModule` (see [docs/SDK.md](docs/SDK.md)); the shell owns layout, motion and input.
- **Your own data source** goes into a connector in its own package, not into the app.

## Before a pull request

- `./scripts/test.sh` is green and `./scripts/build-app.sh` builds.
- New behaviour has a test where it can have one.
- The idle CPU budget holds: under 0.5 % with the island closed. Prefer file events and caches over polling.
- No new dependencies without talking first. No GPL code. Every asset needs a license that allows redistribution; say where it comes from in the pull request.
- No telemetry, no network calls from the core. Nothing that reads other apps' Keychain items.
- Interface text in English; add German to `Resources/Localization/de.lproj/Localizable.strings` if you can.
- Respect Reduce Motion for anything that moves.

## Style

Swift 6 language mode, four spaces, no force unwraps outside tests and fixed literals. Comments say why, not what. Keep functions short and names plain.

## Reporting bugs

Use the bug template: macOS version, Mac model, the display setup (built-in notch, external displays), and what you saw. A screenshot of the island helps; `--capturable` makes it visible to screenshots.
