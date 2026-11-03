import Testing
import TestSupport
@testable import NotchCore

@Suite struct TimeToLeaveTests {
    let start = UTC.date("2026-11-01 18:30")

    @Test func dueFromAMinuteBeforeUntilTheStart() {
        let travel: Double = 18 * 60
        #expect(UTC.string(TimeToLeave.leaveAt(start: start, travel: travel)) == "2026-11-01 18:12")
        #expect(!TimeToLeave.isDue(start: start, travel: travel, now: UTC.date("2026-11-01 18:10")))
        #expect(TimeToLeave.isDue(start: start, travel: travel, now: UTC.date("2026-11-01 18:11")))
        #expect(TimeToLeave.isDue(start: start, travel: travel, now: UTC.date("2026-11-01 18:12")))
        // Late is still worth saying, until it starts.
        #expect(TimeToLeave.isDue(start: start, travel: travel, now: UTC.date("2026-11-01 18:29")))
        #expect(!TimeToLeave.isDue(start: start, travel: travel, now: start))
    }

    @Test func onlyRoutesAcrossTownCount() {
        #expect(!TimeToLeave.usable(60))
        #expect(TimeToLeave.usable(2 * 60))
        #expect(TimeToLeave.usable(45 * 60))
        #expect(!TimeToLeave.usable(4 * 3600))
    }

    @Test func aPlaceIsSomewhereToGo() {
        #expect(TimeToLeave.hasPlace(location: "Torstraße 10, Berlin", hasCoordinate: false, hasCallLink: false, isRoom: false))
        #expect(!TimeToLeave.hasPlace(location: "  ", hasCoordinate: false, hasCallLink: false, isRoom: false))
        #expect(!TimeToLeave.hasPlace(location: nil, hasCoordinate: false, hasCallLink: false, isRoom: false))
        // A call's location text isn't a place; a meeting room has no way to go.
        #expect(!TimeToLeave.hasPlace(location: "Microsoft Teams Meeting", hasCoordinate: false, hasCallLink: true, isRoom: false))
        #expect(!TimeToLeave.hasPlace(location: "https://zoom.us/j/1", hasCoordinate: false, hasCallLink: false, isRoom: false))
        #expect(!TimeToLeave.hasPlace(location: "Room 2", hasCoordinate: true, hasCallLink: false, isRoom: true))
        // Coordinates from Calendar always are, also with a link (in person and online).
        #expect(TimeToLeave.hasPlace(location: "Office", hasCoordinate: true, hasCallLink: true, isRoom: false))
    }

    @Test func looksUpWithinTheHorizonAndNotTooOften() {
        let now = UTC.date("2026-11-01 15:00")
        // Too far ahead, already started.
        #expect(!TimeToLeave.needsLookup(start: UTC.date("2026-11-01 19:30"), now: now, found: nil, travel: nil, failed: nil))
        #expect(TimeToLeave.needsLookup(start: UTC.date("2026-11-01 18:30"), now: now, found: nil, travel: nil, failed: nil))
        #expect(!TimeToLeave.needsLookup(start: UTC.date("2026-11-01 14:30"), now: now, found: nil, travel: nil, failed: nil))
        // An answer is asked again after a quarter of an hour, a failure after half an hour.
        #expect(!TimeToLeave.needsLookup(start: start, now: now, found: UTC.date("2026-11-01 14:50"), travel: 900, failed: nil))
        #expect(TimeToLeave.needsLookup(start: start, now: now, found: UTC.date("2026-11-01 14:45"), travel: 900, failed: nil))
        #expect(!TimeToLeave.needsLookup(start: start, now: now, found: nil, travel: nil, failed: UTC.date("2026-11-01 14:40")))
        #expect(TimeToLeave.needsLookup(start: start, now: now, found: nil, travel: nil, failed: UTC.date("2026-11-01 14:30")))
        // Once it's time to go the answer stays as it is.
        #expect(!TimeToLeave.needsLookup(start: start, now: UTC.date("2026-11-01 18:20"), found: UTC.date("2026-11-01 17:50"),
                                         travel: 18 * 60, failed: nil))
    }

    @Test func durations() {
        #expect(TimeToLeave.duration(30) == "1 min")
        #expect(TimeToLeave.duration(18 * 60) == "18 min")
        #expect(TimeToLeave.duration(17 * 60 + 5) == "18 min")
        #expect(TimeToLeave.duration(3600) == "1 h")
        #expect(TimeToLeave.duration(65 * 60) == "1 h 5 min")
    }

    @Test func oneLinePerEventAndDay() {
        var alerts = LeaveAlerts()
        #expect(!alerts.contains("dinner", day: "2026-11-01"))
        alerts.insert("dinner", day: "2026-11-01")
        alerts.insert("dinner", day: "2026-11-01")
        #expect(alerts.contains("dinner", day: "2026-11-01") && alerts.ids == ["dinner"])
        // A recurring event shares its id: the next day it may show again.
        #expect(!alerts.contains("dinner", day: "2026-11-02"))
        alerts.insert("gym", day: "2026-11-02")
        #expect(alerts.ids == ["gym"] && alerts.day == "2026-11-02")
    }

    @Test func settingsStartOnAndKeepOlderSaves() {
        let settings = SwitcherSettings()
        #expect(settings.timeToLeave && settings.travelMode == .driving && settings.shelfActions && settings.shelfKeeps)
        let isolated = IsolatedSettings()
        isolated.writeRaw(#"{"didOnboard":true}"#)
        let older = isolated.store.load()
        // Saved before Time to leave: it stays off until switched on.
        #expect(!older.timeToLeave && older.travelMode == .driving && older.shelfActions && older.shelfKeeps)
        // A new install's saves keep it on.
        isolated.store.save(settings)
        #expect(isolated.store.load().timeToLeave)
        var changed = settings
        changed.timeToLeave = false
        changed.travelMode = .transit
        changed.shelfActions = false
        changed.shelfKeeps = false
        isolated.store.save(changed)
        let loaded = isolated.store.load()
        #expect(!loaded.timeToLeave && loaded.travelMode == .transit && !loaded.shelfActions && !loaded.shelfKeeps)
    }
}
