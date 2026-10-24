import Testing
@testable import NotchCore

@Suite struct HoverLockTests {
    @Test func locksUntilEveryHolderReleases() {
        var lock = HoverLock()
        #expect(!lock.isLocked)
        let airplay = lock.acquire("airplay")
        let menu = lock.acquire("menu")
        #expect(lock.isLocked)
        #expect(lock.reasons == ["airplay", "menu"])
        let first = lock.release(airplay)
        #expect(first == false)                    // still held by the menu
        #expect(lock.isLocked)
        let second = lock.release(menu)
        #expect(second == true)                    // this one unlocked
        #expect(!lock.isLocked)
    }

    @Test func doubleOrUnknownReleaseIsHarmless() {
        var lock = HoverLock()
        let token = lock.acquire("x")
        let once = lock.release(token)
        let twice = lock.release(token)
        let unknown = lock.release(999)
        #expect(once)
        #expect(!twice)
        #expect(!unknown)
        #expect(!lock.isLocked)
    }
}
