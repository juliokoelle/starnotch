import Foundation

/// A folder in Apple Notes, where quick capture copies notes to.
public struct AppleNotesFolder: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The account it is in ("iCloud", "On My Mac").
    public var account: String

    public init(id: String, name: String, account: String) {
        self.id = id
        self.name = name
        self.account = account
    }

    /// Notes' own default folder (of its default account), whatever it is called.
    public static let notesDefault = AppleNotesFolder(id: "", name: "", account: "")
    public var isNotesDefault: Bool { id.isEmpty }

    /// "iCloud › Notes".
    public var label: String { account.isEmpty ? name : "\(account) › \(name)" }
}

/// One note as the Notepad lists it.
public struct AppleNote: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var modified: Date
    /// Password protected: listed without its text, which is never read.
    public var locked: Bool
    /// The line after the title; nil until it was read.
    public var preview: String?

    public init(id: String, title: String, folder: String, modified: Date, locked: Bool, preview: String? = nil) {
        self.id = id
        self.title = title
        self.folder = folder
        self.modified = modified
        self.locked = locked
        self.preview = preview
    }
}

/// The AppleScript Starnotch sends Notes.app, and reading what comes back. Values go in as
/// arguments, never into the source; each starts with `_`, so a text that begins with "-" isn't
/// taken for an option of `osascript`. A list comes back as records split by control characters
/// that don't occur in names; a date as its local year, month, day and seconds since midnight.
/// Notes is only read, and only ever gets new notes: no script moves or deletes one.
public enum AppleNotesScript {
    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// `arg(argv, i)`: the i-th argument without its `_`.
    private static let argHandler = """
    on arg(argv, i)
        set v to item i of argv
        if length of v < 2 then return ""
        return text 2 thru -1 of v
    end arg
    """

    /// An argument as the scripts take it.
    public static func argument(_ value: String) -> String { "_" + value }

    /// Every note's id, name, modification date, lock and folder, one Apple event per property.
    /// The lists are checked to line up (a note made in between shifts them).
    public static let list = """
    on run
        script L
            property ids : {}
            property names : {}
            property dates : {}
            property locks : {}
            property folders : {}
            property out : {}
        end script
        tell application "Notes"
            set L's ids to id of every note
            set L's names to name of every note
            set L's dates to modification date of every note
            set L's locks to password protected of every note
            try
                set L's folders to name of container of every note
            end try
        end tell
        set n to count of L's ids
        if (count of L's names) is not n or (count of L's dates) is not n or (count of L's locks) is not n then error "The notes changed while they were read." number -10000
        set withFolders to (count of L's folders) is n
        set f to character id 31
        repeat with i from 1 to n
            set d to item i of L's dates
            set stamp to ((year of d) as integer as text) & "-" & ((month of d) as integer as text) & "-" & (day of d as text) & "-" & (time of d as text)
            if withFolders then
                set folderName to item i of L's folders
            else
                set folderName to ""
            end if
            set end of L's out to (item i of L's ids) & f & (item i of L's names) & f & stamp & f & ((item i of L's locks) as text) & f & folderName
        end repeat
        set AppleScript's text item delimiters to character id 30
        return (L's out) as text
    end run
    """

    /// The plain text of the notes changed since a time (arguments: year, month, day, seconds since
    /// midnight, then the ids wanted), at most 600 characters each, never of a locked note. Asked
    /// in one go with a `whose` filter; should Notes not take it, or answer with more than
    /// expected, one note at a time instead.
    public static let contents = argHandler + "\n\n" + """
    on run argv
        set cutoff to current date
        set day of cutoff to 1
        set year of cutoff to (arg(argv, 1)) as integer
        set month of cutoff to (arg(argv, 2)) as integer
        set day of cutoff to (arg(argv, 3)) as integer
        set time of cutoff to (arg(argv, 4)) as integer
        set wanted to {}
        repeat with i from 5 to count of argv
            set end of wanted to arg(argv, i)
        end repeat
        script L
            property ids : {}
            property texts : {}
            property out : {}
        end script
        tell application "Notes"
            try
                if (count of (notes whose modification date is greater than or equal to cutoff and password protected is false)) > 40 then error "Too many"
                set L's ids to id of (notes whose modification date is greater than or equal to cutoff and password protected is false)
                set L's texts to plaintext of (notes whose modification date is greater than or equal to cutoff and password protected is false)
                if (count of L's ids) is not (count of L's texts) then error "Changed"
            on error
                set L's ids to {}
                set L's texts to {}
                repeat with wantedID in wanted
                    try
                        set theNote to note id (contents of wantedID)
                        if password protected of theNote is false then
                            set theText to plaintext of theNote
                            set end of L's ids to contents of wantedID
                            set end of L's texts to theText
                        end if
                    end try
                end repeat
            end try
        end tell
        set f to character id 31
        repeat with i from 1 to count of L's ids
            set t to item i of L's texts
            if length of t > 600 then set t to text 1 thru 600 of t
            set end of L's out to (item i of L's ids) & f & t
        end repeat
        set AppleScript's text item delimiters to character id 30
        return (L's out) as text
    end run
    """

    /// The folders of every account: id, name and the account's name.
    public static let folders = """
    on run
        script L
            property out : {}
        end script
        tell application "Notes"
            repeat with theAccount in every account
                set accountName to name of theAccount
                set theIDs to id of every folder of theAccount
                set theNames to name of every folder of theAccount
                repeat with i from 1 to count of theIDs
                    set end of L's out to (item i of theIDs) & (character id 31) & (item i of theNames) & (character id 31) & accountName
                end repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to character id 30
        return (L's out) as text
    end run
    """

    /// The error number `create` stops with when the folder picked for captures is gone.
    public static let folderGone = 1001

    /// A new note (arguments: the folder's id, "" for Notes' default folder; the body as HTML);
    /// answers its id. A folder that is gone is an error, never the default folder: that can be
    /// in another account, one that syncs.
    public static let create = argHandler + "\n\n" + """
    on run argv
        set folderID to arg(argv, 1)
        set theBody to arg(argv, 2)
        tell application "Notes"
            if folderID is "" then
                set target to default folder of default account
            else
                if not (exists folder id folderID) then error "The folder for captures is no longer in Notes." number \(folderGone)
                set target to folder id folderID
            end if
            set madeNote to make new note at target with properties {body:theBody}
            return id of madeNote
        end tell
    end run
    """

    /// Brings Notes forward on one note (argument: its id).
    public static let show = argHandler + "\n\n" + """
    on run argv
        set noteID to arg(argv, 1)
        tell application "Notes"
            show note id noteID
            activate
        end tell
    end run
    """

    /// The arguments for `contents`: the oldest of `notes`' modification dates, then their ids.
    public static func contentsArguments(for notes: [AppleNote], calendar: Calendar) -> [String] {
        guard let oldest = notes.map(\.modified).min() else { return [] }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: oldest)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return ([parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, seconds].map(String.init) + notes.map(\.id)).map(argument)
    }
}

/// Reading Notes' answers and keeping the list short.
public enum AppleNotesFormat {
    /// How many notes the Notepad lists.
    public static let shown = 20

    /// The trash ("Recently Deleted") in the languages Notes is used in most; the scripting
    /// interface has no other way to tell it apart.
    static let trashNames: Set<String> = ["recently deleted", "zuletzt gelöscht", "supprimés récemment", "eliminados recientemente",
                                          "eliminadas recientemente", "eliminati di recente", "recent verwijderd", "nyligen raderade",
                                          "senest slettet", "nylig slettet", "apagadas recentemente", "apagados recentemente"]

    public static func isTrash(folder: String) -> Bool { trashNames.contains(folder.lowercased()) }

    /// The `list` script's answer; malformed records are skipped.
    public static func notes(from output: String, calendar: Calendar) -> [AppleNote] {
        records(output).compactMap { fields in
            guard fields.count == 5, !fields[0].isEmpty, let modified = date(fields[2], calendar: calendar) else { return nil }
            return AppleNote(id: fields[0], title: fields[1].trimmingCharacters(in: .whitespacesAndNewlines), folder: fields[4],
                             modified: modified, locked: fields[3] == "true")
        }
    }

    /// The `contents` script's answer: the line after the title for each id.
    public static func previews(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        for fields in records(output) where fields.count == 2 && !fields[0].isEmpty {
            result[fields[0]] = NoteNaming.preview(of: fields[1])
        }
        return result
    }

    /// The `folders` script's answer, the trash left out.
    public static func folders(from output: String) -> [AppleNotesFolder] {
        records(output).compactMap { fields in
            guard fields.count == 3, !fields[0].isEmpty, !isTrash(folder: fields[1]) else { return nil }
            return AppleNotesFolder(id: fields[0], name: fields[1], account: fields[2])
        }
    }

    /// The newest `limit` notes, the trash left out.
    public static func newest(_ notes: [AppleNote], limit: Int = shown) -> [AppleNote] {
        Array(notes.filter { !isTrash(folder: $0.folder) }.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// A fresh list with the lines already read kept where the note hasn't changed since; and the
    /// notes whose line has to be read (not the locked ones).
    public static func merge(_ fresh: [AppleNote], cached: [AppleNote]) -> (notes: [AppleNote], missing: [AppleNote]) {
        let known = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let notes = fresh.map { note -> AppleNote in
            var note = note
            if !note.locked, let old = known[note.id], old.modified == note.modified { note.preview = old.preview }
            return note
        }
        return (notes, notes.filter { !$0.locked && $0.preview == nil })
    }

    /// A capture as a note's body: one paragraph per line, the first one is the note's title.
    public static func body(for text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        return lines.map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return escaped.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(escaped)</div>"
        }.joined()
    }

    /// The error number in what `osascript` wrote to stderr ("… (-1743)"), if any.
    public static func errorNumber(in stderr: String) -> Int? {
        guard let match = stderr.firstMatch(of: #/\((-?\d+)\)\s*$/#) else { return nil }
        return Int(match.output.1)
    }

    /// "2026-10-31-43200": year, month, day, seconds since midnight, in local time.
    static func date(_ stamp: String, calendar: Calendar) -> Date? {
        let parts = stamp.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 4, (1...12).contains(parts[1]), (1...31).contains(parts[2]), (0..<86_400).contains(parts[3]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                  hour: parts[3] / 3600, minute: parts[3] % 3600 / 60, second: parts[3] % 60))
    }

    private static func records(_ output: String) -> [[String]] {
        output.split(separator: AppleNotesScript.recordSeparator, omittingEmptySubsequences: true).map { record in
            // osascript ends its answer with a line break.
            let trimmed = record.hasSuffix("\n") ? record.dropLast() : record[...]
            return trimmed.split(separator: AppleNotesScript.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        }
    }
}
