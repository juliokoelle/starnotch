# Extending Starnotch

Three ways in, from the lightest:

1. **The local status API**: any script posts a line to the notch.
2. **Connectors**: your own data in the built-in modules (Today, loops, meeting prep, quick capture).
3. **Modules**: a new panel in the island.

Plus [character packs](CHARACTER_PACKS.md) for your own characters.

## Local status API

Switch on *Local status API* in Settings. The app then listens on `127.0.0.1:47789` (loopback only; the port is `[api] port` in config.toml) and keeps a token in `~/Library/Application Support/Starnotch/api-token` (0600).

```sh
curl -s http://127.0.0.1:47789/status \
  -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Starnotch/api-token)" \
  -H "Content-Type: application/json" \
  -d '{"title":"Build done","detail":"42 tests","tint":"ok","icon":"checkmark.circle"}'
```

`scripts/notch-status.sh TITLE [DETAIL] [TINT] [KEY]` does the same and keeps the token out of the process list.

| Field | Meaning |
|---|---|
| `title` | Required (unless `loop` is set), up to 80 characters |
| `detail` | Second line |
| `tint` | `accent`, `ok`, `waiting`, `critical`, `neutral` |
| `icon` | An SF Symbol name |
| `url` | `http(s)` link the line opens when clicked |
| `seconds` | How long it shows, 1 to 10 (default 3) |
| `key` | Lines with the same key replace each other |
| `loop`, `state` | Updates a loop: `running`, `ok`, `fail`, `waiting` |

Without the server, a link works too: `open "starnotch://status?title=Build%20done&tint=ok"`.

## Connectors

A connector is a Swift class in its own package. It adopts `NotchConnector` and any of the capability protocols from `NotchCore` (`Sources/NotchCore/Connectors.swift`):

| Protocol | Feeds | You implement |
|---|---|---|
| `TodayProvider` | the Today module | `today(now:) -> TodayFeed` |
| `JobsProvider` | the loops strip, list, timeline and finished sneaks | `loops(now:) -> [LoopStatus]`, optional `logURL`, `specLinkTitle` |
| `PeopleProvider` | names in quick capture, meeting prep in the calendar | `people()`, `prep(attendees:now:)`, optional `noteURL(for:)`, `prepTitle` |
| `InboxSink` | quick capture | `file(_ capture:) async -> CaptureOutcome` |

The first connector that offers a capability provides it. Items carry their own links (`url`), so a click opens the connector's own app or page.

```swift
import Foundation
import NotchCore

public final class MyConnector: NotchConnector, TodayProvider, @unchecked Sendable {
    public static let id = "example"                 // config: [connectors.example]
    public static let displayName = "Example"

    private let file: URL?

    public init(config: ConfigSection) {
        file = config.path("tasks_file")             // ~ is expanded
    }

    public func today(now: Date) -> TodayFeed {
        let lines = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let items = lines.split(separator: "\n").enumerated().map { index, line in
            TodayItem(id: "t\(index)", kind: .task, title: String(line))
        }
        return TodayFeed(now: items, emptyText: "Nothing for today.")
    }
}
```

Rules of thumb:

- **Fast and quiet.** `loops(now:)` runs off the main thread on every agent scan; `today(now:)` and `prep` run on the main thread when a panel opens. Cache by modification time and read small files.
- **Never lose a capture.** An `InboxSink` that can't reach its destination keeps a local copy and returns `.queued(reason:)`.
- **Thread safety.** Connectors are `Sendable`; guard caches with a lock (or keep them immutable).
- **Configuration** comes from your table in config.toml: `config.string`, `.path`, `.url`, `.bool`, `.int`, `.strings`.

### Building with your connector

Connectors are linked at build time, so a build with connectors is its own small package that depends on this one:

```swift
// Package.swift of your build
dependencies: [.package(path: "../starnotch")],
targets: [
    .target(name: "MyConnector", dependencies: [.product(name: "NotchCore", package: "starnotch")]),
    .executableTarget(name: "MyNotch", dependencies: [
        "MyConnector", .product(name: "NotchKit", package: "starnotch"),
    ]),
]
```

```swift
// Sources/MyNotch/main.swift
import NotchKit
import MyConnector

NotchApp.main(connectors: [MyConnector.self], buildConfig: """
[connectors.example]
tasks_file = "~/Documents/today.txt"
""")
```

`buildConfig` holds your build's defaults in config.toml syntax; the user's `config.toml` overrides them key by key. `[connectors] enabled = ["example"]` limits which linked connectors run.

Bundle it with the same script, pointed at your package:

```sh
NOTCH_PACKAGE=../my-notch NOTCH_PRODUCT=MyNotch APP_NAME="My Notch" BUNDLE_ID=com.example.mynotch \
NOTCH_EXTRA_PACKS=../my-notch/Packs/mine.notchpack ./scripts/build-app.sh
```

`SUPPORT_FOLDER` and `URL_SCHEME` set the Application Support folder and the link scheme of that build.

## Modules

A module is a class adopting `NotchModule` (`Sources/NotchKit/Modules/NotchModule.swift`). It provides views and state; the shell owns layout, motion and input.

| Member | Purpose |
|---|---|
| `kind`, `symbol`, `count` | Tab identity, SF Symbol, the small number on the tab |
| `ambientPriority` | How much it wants the ears at rest (dictation 40, a meeting soon 30, agents at work 20, music 15) |
| `leadingEar(peek:)`, `trailingEar(peek:)` | Beside the hardware notch, 24 pt wide at rest |
| `peekLine()` | One line under the notch on hover |
| `body()` | The expanded panel: one size for every tab (`NotchLayout.expandedWidth` by `NotchLayout.panelHeight`); fill it and scroll what is longer |
| `primaryAction()`, `handleKey(_:)`, `handleBack()` | Return, arrow keys, Escape |
| `setExpanded(_:)` | Start or stop expensive work |

Modules live in this repository for now (`ModuleKind` lists them). Use `NotchCard`, `HoverRow`, `PressScale` and `Theme` for a consistent look, and keep idle work near zero: no timers while the panel is closed.
