import Testing
@testable import NotchCore

@Suite struct CameraCheckTests {
    @Test func accessFromTheSystemStatus() {
        #expect(CameraCheck.Access(status: 0) == .notAsked)
        #expect(CameraCheck.Access(status: 1) == .denied)  // restricted
        #expect(CameraCheck.Access(status: 2) == .denied)
        #expect(CameraCheck.Access(status: 3) == .allowed)
    }

    @Test func allowedShowsAndASecondClickCloses() {
        var check = CameraCheck()
        #expect(!check.cameraOn)
        #expect(check.click("review", access: .allowed) == .show)
        #expect(check.cameraOn && check.meetingID == "review" && check.card == .preview)
        #expect(check.click("review", access: .allowed) == .close)
        #expect(!check.cameraOn && check.meetingID == nil)
    }

    @Test func theFirstClickLetsMacOSAsk() {
        var check = CameraCheck()
        #expect(check.click("review", access: .notAsked) == .ask)
        // Nothing runs while the dialog is up.
        #expect(!check.cameraOn && check.asking == "review")
        check.answered("review", granted: true)
        #expect(check.cameraOn && check.asking == nil)

        var declined = CameraCheck()
        _ = declined.click("review", access: .notAsked)
        declined.answered("review", granted: false)
        #expect(!declined.cameraOn && declined.card == .accessOff)
    }

    @Test func anAnswerAfterTheCardWentAwayStartsNothing() {
        var check = CameraCheck()
        _ = check.click("review", access: .notAsked)
        check.left("review")
        check.answered("review", granted: true)
        #expect(!check.cameraOn && check.meetingID == nil)
        // Closed (the panel closed) while asking: the same.
        _ = check.click("review", access: .notAsked)
        check.close()
        check.answered("review", granted: true)
        #expect(!check.cameraOn)
    }

    @Test func accessOffExplainsAndOpensSettings() {
        var check = CameraCheck()
        #expect(check.click("review", access: .denied) == .openSettings)
        #expect(!check.cameraOn && check.card == .accessOff && check.meetingID == "review")
        // A second click closes the note.
        #expect(check.click("review", access: .denied) == .close)
        #expect(check.card == nil)
    }

    @Test func leavingACardStopsOnlyItsOwnCamera() {
        var check = CameraCheck()
        _ = check.click("review", access: .allowed)
        // Another meeting's card went away (its view left after the selection moved on).
        check.left("intro")
        #expect(check.cameraOn)
        check.left("review")
        #expect(!check.cameraOn)
        // Another card's click moves the check there.
        _ = check.click("review", access: .allowed)
        #expect(check.click("intro", access: .allowed) == .show)
        #expect(check.meetingID == "intro" && check.cameraOn)
    }
}
