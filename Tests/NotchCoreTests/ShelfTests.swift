import Foundation
import Testing
@testable import NotchCore

@Suite struct ShelfTests {
    @Test func zipNamesFollowFinder() {
        #expect(ShelfNames.zip(of: "Report.pdf") == "Report.pdf.zip")
        #expect(ShelfNames.zip(of: "Photos") == "Photos.zip")
    }

    @Test func aFreeNameNeverReplacesAFile() {
        let taken: Set<String> = ["Report.pdf", "Report 2.pdf", "Report.pdf.zip", "Photos", ".env"]
        #expect(ShelfNames.free("Notes.txt") { taken.contains($0) } == "Notes.txt")
        #expect(ShelfNames.free("Report.pdf") { taken.contains($0) } == "Report 3.pdf")
        #expect(ShelfNames.free("Report.pdf.zip") { taken.contains($0) } == "Report.pdf 2.zip")
        #expect(ShelfNames.free("Photos") { taken.contains($0) } == "Photos 2")
        // A hidden file's dot isn't an extension.
        #expect(ShelfNames.free(".env") { taken.contains($0) } == ".env 2")
    }

    @Test func aFolderDoesNotGoIntoItself() {
        #expect(ShelfNames.isInside("/Users/me/Photos", of: "/Users/me/Photos"))
        #expect(ShelfNames.isInside("/Users/me/Photos/2026", of: "/Users/me/Photos/"))
        #expect(!ShelfNames.isInside("/Users/me/Photos 2", of: "/Users/me/Photos"))
        #expect(!ShelfNames.isInside("/Users/me", of: "/Users/me/Photos"))
    }

    @Test func theTrashIsGone() {
        #expect(ShelfMemory.isInTrash("/Users/me/.Trash/Report.pdf"))
        #expect(ShelfMemory.isInTrash("/Volumes/Disk/.Trashes/501/Report.pdf"))
        #expect(!ShelfMemory.isInTrash("/Users/me/Trash notes.txt"))
    }

    /// Files in a folder of their own, removed afterwards.
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func comesBackInOrderAndFollowsAMovedFile() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.txt"), second = folder.appending(path: "second.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let saved = try JSONEncoder().encode(ShelfMemory([second, first, second]))

        // Renamed while the app was closed: the bookmark finds it under its new name.
        let renamed = folder.appending(path: "renamed.txt")
        try FileManager.default.moveItem(at: second, to: renamed)
        let back = try JSONDecoder().decode(ShelfMemory.self, from: saved).restore()
        #expect(back.map(\.lastPathComponent) == ["renamed.txt", "first.txt"])
    }

    @Test func aFileThatIsGoneDropsOutQuietly() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appending(path: "kept.txt"), gone = folder.appending(path: "gone.txt")
        try Data("a".utf8).write(to: kept)
        try Data("b".utf8).write(to: gone)
        let memory = ShelfMemory([gone, kept])
        try FileManager.default.removeItem(at: gone)
        #expect(memory.restore().map(\.lastPathComponent) == ["kept.txt"])
        // Without a bookmark the path still counts while the file is there.
        let plain = ShelfMemory(items: [.init(path: kept.path, bookmark: nil), .init(path: gone.path, bookmark: nil)])
        #expect(plain.restore().map(\.lastPathComponent) == ["kept.txt"])
        #expect(ShelfMemory([]).restore().isEmpty)
    }
}
