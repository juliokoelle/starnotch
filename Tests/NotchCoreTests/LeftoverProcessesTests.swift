import Testing
@testable import NotchCore

@Suite struct LeftoverProcessesTests {
    let boring = "/Applications/boringNotch.app"

    // The Perl helper Boring Notch 2.7.3 leaves behind after it quits.
    let adapter = ProcessSnapshot(pid: 500, parentPID: 1, arguments: [
        "/usr/bin/perl",
        "/Applications/boringNotch.app/Contents/Resources/mediaremote-adapter.pl",
        "/Applications/boringNotch.app/Contents/Frameworks/MediaRemoteAdapter.framework",
        "stream",
    ])

    @Test func selectsOrphanedHelperOfQuitApp() {
        #expect(LeftoverProcesses.select([adapter], bundlePaths: [boring]) == [500])
    }

    @Test func ignoresHelpersThatStillHaveAParent() {
        var child = adapter
        child.parentPID = 420
        #expect(LeftoverProcesses.select([child], bundlePaths: [boring]).isEmpty)
    }

    @Test func ignoresOtherBundlesAndPrefixLookalikes() {
        let other = ProcessSnapshot(pid: 501, parentPID: 1, arguments: ["/Applications/Atoll.app/Contents/MacOS/Atoll"])
        let lookalike = ProcessSnapshot(pid: 502, parentPID: 1, arguments: ["/Applications/boringNotch.app.bak/run"])
        let mention = ProcessSnapshot(pid: 503, parentPID: 1, arguments: ["/bin/zsh", "-c", "open /Applications/boringNotch.app"])
        #expect(LeftoverProcesses.select([other, lookalike, mention], bundlePaths: [boring]).isEmpty)
    }

    @Test func toleratesTrailingSlashAndSkipsLaunchdAndExcluded() {
        let launchd = ProcessSnapshot(pid: 1, parentPID: 0, arguments: ["/Applications/boringNotch.app/x"])
        let selected = LeftoverProcesses.select([launchd, adapter], bundlePaths: [boring + "/"], excluding: [500])
        #expect(selected.isEmpty)
    }

    @Test func parsesProcArgs2Buffer() {
        // argc, exec path, padding, argv, environment
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += cString("/usr/bin/perl") + [0, 0]
        for argument in ["perl", "/a.pl", "stream", "HOME=/Users/x"] {
            bytes += cString(argument)
        }
        #expect(ProcessSnapshot.arguments(fromProcArgs2: bytes) == ["perl", "/a.pl", "stream"])
    }

    @Test func parsesTruncatedOrEmptyBuffers() {
        #expect(ProcessSnapshot.arguments(fromProcArgs2: []) == [])
        let noArguments: [UInt8] = [2, 0, 0, 0] + Array("/bin/x".utf8)
        #expect(ProcessSnapshot.arguments(fromProcArgs2: noArguments) == [])
        let short: [UInt8] = [2, 0, 0, 0] + cString("/bin/x") + cString("x")
        #expect(ProcessSnapshot.arguments(fromProcArgs2: short) == ["x"])
    }

    private func cString(_ string: String) -> [UInt8] {
        Array(string.utf8) + [0]
    }
}
