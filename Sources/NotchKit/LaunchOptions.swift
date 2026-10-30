import NotchCore
/// Command line flags for demos, screenshots and manual testing.
///
///     open "Starnotch.app" --args --expand agents
struct LaunchOptions {
    /// Fill the bottom slot with a built-in app (Calculator) to try app switching.
    var demoSlots = false
    /// Open the wheel in click mode right after launch.
    var openWheel = false
    /// Open the settings window right after launch.
    var openSettings = false
    /// Open the notch on a module right after launch (`agents`, `today`, `calendar`, `nowPlaying`, `dictation`, `loops`, `peek`).
    var expand: String?
    /// Show the "finished" moment on the main session shortly after launch.
    var demoFinished = false
    /// Open the settings with the bottom slot's picker showing.
    var openSlotPicker = false
    /// Open the settings with the home project's character picker showing.
    var openProjectPicker = false
    /// Round-4 design preview with mock data (see `PreviewDirector`); implies --capturable.
    var preview: String?
    /// Sample meetings instead of EventKit (no calendar permission needed).
    var mockCalendar = false
    /// Let screenshots and recordings see the island (it's hidden from screen capture otherwise).
    var capturable = false
    /// Post a sample sneak peek (an agent finishing) shortly after launch.
    var demoSneak = false
    /// Play a scripted tour (peek, expand, wheel, switch) for recordings, then quit.
    var tour = false
    /// Test mode: sample agents, calendar, Today and music, no permissions, nothing written.
    var sampleData = false
    /// Open onboarding right after launch, even when it was done; `--onboarding-step 0…8` picks the step
    /// (Tara, agents, calendar, music, meetings, Tara's brain, notes, tools, and 8 for the AI apps
    /// that read Tara's memory, which comes before the tools).
    var onboarding = false
    var onboardingStep: Int?
    /// Open the memory map in its own window; made-up data with `--preview memory-map` or
    /// `--sample-data`, and `--memory-map-nodes 1500` sets how big the made-up map is.
    var openMemoryMap = false
    var memoryMapNodes: Int?
    /// Open the Dashboard right after launch; `--dashboard-section` picks the page (`home`,
    /// `timeline`, `characters`, `brain`, `ask`, `meetings`, `captures`, `integrations`, `privacy`, `settings`;
    /// `memoryMap` and `connections` still work), with an integration's page or a part of Settings
    /// after a colon (`integrations:calendar`, `settings:agents`). With `--preview dashboard` or
    /// `--sample-data` it shows made-up activity; `--dashboard-state empty|loading|error` shows
    /// the cards' other states and `--appearance light|dark` fixes its look for screenshots.
    var openDashboard = false
    var dashboardSection: String?
    var dashboardState: String?
    var appearance: String?
    /// Screenshots of long pages: `--dashboard-scroll center|bottom` starts the page there.
    var dashboardScroll: String?

    init(arguments: [String] = CommandLine.arguments) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--demo-slots": demoSlots = true
            case "--open-wheel": openWheel = true
            case "--open-settings": openSettings = true
            case "--expand": expand = iterator.next()
            case "--tour": tour = true
            case "--sample-data": sampleData = true
            case "--demo-finished": demoFinished = true
            case "--demo-sneak": demoSneak = true
            case "--capturable": capturable = true
            case "--mock-calendar": mockCalendar = true
            case "--preview": preview = iterator.next()
            case "--open-slot-picker": openSlotPicker = true
            case "--open-project-picker": openProjectPicker = true
            case "--onboarding": onboarding = true
            case "--open-memory-map": openMemoryMap = true
            case "--memory-map-nodes": memoryMapNodes = iterator.next().flatMap(Int.init)
            case "--open-dashboard": openDashboard = true
            case "--dashboard-section": dashboardSection = iterator.next()
            case "--dashboard-state": dashboardState = iterator.next()
            case "--appearance": appearance = iterator.next()
            case "--dashboard-scroll": dashboardScroll = iterator.next()
            case "--onboarding-step":
                onboarding = true
                onboardingStep = iterator.next().flatMap(Int.init)
            default: break
            }
        }
    }
}
