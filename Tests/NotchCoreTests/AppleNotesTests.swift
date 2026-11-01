import Testing
import TestSupport
@testable import NotchCore

@Suite struct AppleNotesTests {
    let cal = UTC.calendar
    let f = "\u{1F}", r = "\u{1E}"

    func note(_ id: String, _ modified: String, folder: String = "Notes", locked: Bool = false, preview: String? = nil) -> AppleNote {
        AppleNote(id: id, title: id, folder: folder, modified: UTC.date(modified), locked: locked, preview: preview)
    }

    @Test func readsTheListAndSkipsWhatDoesntParse() {
        let output = ["x-coredata://A/ICNote/p1\(f)Offsite agenda\(f)2026-10-31-43200\(f)false\(f)Notes",
                      "x-coredata://A/ICNote/p2\(f)Diary \(f)2026-10-30-3725\(f)true\(f)Private",
                      "broken\(f)no date\(f)yesterday\(f)false\(f)Notes",
                      "short\(f)record"].joined(separator: r) + "\n"
        let notes = AppleNotesFormat.notes(from: output, calendar: cal)
        #expect(notes.count == 2)
        #expect(notes[0].title == "Offsite agenda" && UTC.string(notes[0].modified) == "2026-10-31 12:00" && !notes[0].locked)
        #expect(notes[1].title == "Diary" && notes[1].locked && notes[1].folder == "Private")
        #expect(UTC.string(notes[1].modified) == "2026-10-30 01:02")
        #expect(AppleNotesFormat.notes(from: "\n", calendar: cal).isEmpty)
    }

    @Test func keepsTheNewestOutsideTheTrash() {
        let notes = [note("old", "2026-10-01 09:00"), note("new", "2026-10-31 09:00"),
                     note("gone", "2026-10-31 10:00", folder: "Zuletzt gelöscht"), note("mid", "2026-10-15 09:00"),
                     note("deleted", "2026-10-31 11:00", folder: "Recently Deleted")]
        #expect(AppleNotesFormat.newest(notes, limit: 2).map(\.id) == ["new", "mid"])
        #expect(AppleNotesFormat.newest(notes).count == 3)
    }

    @Test func keepsTheLinesAlreadyReadUntilANoteChanges() {
        let cached = [note("a", "2026-10-31 09:00", preview: "first line"), note("b", "2026-10-30 09:00", preview: "old line")]
        let fresh = [note("a", "2026-10-31 09:00"), note("b", "2026-10-31 08:00"), note("c", "2026-10-29 09:00"),
                     note("lock", "2026-10-28 09:00", locked: true)]
        let merged = AppleNotesFormat.merge(fresh, cached: cached)
        #expect(merged.notes.map(\.preview) == ["first line", nil, nil, nil])
        // Locked notes are never read.
        #expect(merged.missing.map(\.id) == ["b", "c"])
    }

    @Test func readsTheLineAfterTheTitle() {
        let output = "p1\(f)Groceries\n\n- oat milk\n- lemons\(r)p2\(f)Only a title\(r)\(f)orphan\n"
        let previews = AppleNotesFormat.previews(from: output)
        #expect(previews == ["p1": "- oat milk - lemons", "p2": ""])
    }

    @Test func readsFoldersWithoutTheTrash() {
        let output = "f1\(f)Notes\(f)iCloud\(r)f2\(f)Recently Deleted\(f)iCloud\(r)f3\(f)Work\(f)On My Mac\n"
        let folders = AppleNotesFormat.folders(from: output)
        #expect(folders.map(\.label) == ["iCloud › Notes", "On My Mac › Work"])
        #expect(AppleNotesFolder.notesDefault.isNotesDefault && !folders[0].isNotesDefault)
    }

    @Test func aCaptureBecomesEscapedParagraphs() {
        #expect(AppleNotesFormat.body(for: "Idea: <b>bold</b> & co\n\nsecond line\n") ==
                "<div>Idea: &lt;b&gt;bold&lt;/b&gt; &amp; co</div><div><br></div><div>second line</div>")
    }

    @Test func argumentsCarryTheOldestDateAndAreNeverOptions() {
        let notes = [note("x-coredata://p9", "2026-10-31 09:00"), note("p3", "2026-10-30 01:02")]
        #expect(AppleNotesScript.contentsArguments(for: notes, calendar: cal) ==
                ["_2026", "_10", "_30", "_3720", "_x-coredata://p9", "_p3"])
        #expect(AppleNotesScript.contentsArguments(for: [], calendar: cal).isEmpty)
        #expect(AppleNotesScript.argument("-rf note") == "_-rf note")
    }

    @Test func findsTheErrorNumber() {
        #expect(AppleNotesFormat.errorNumber(in: "execution error: Not authorized to send Apple events to Notes. (-1743)\n") == -1743)
        #expect(AppleNotesFormat.errorNumber(in: "0:12: syntax error") == nil)
    }

    @Test func scriptsOnlyReadOrAdd() {
        // Copy semantics: no script deletes, moves or empties anything in Notes.
        for source in [AppleNotesScript.list, AppleNotesScript.contents, AppleNotesScript.folders, AppleNotesScript.create, AppleNotesScript.show] {
            #expect(!source.contains("delete") && !source.contains("move ") && !source.contains("set body"))
        }
    }
}
