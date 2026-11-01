import Testing
import TestSupport
@testable import NotchCore

@Suite struct DownloadWatchTests {
    /// A watch that has seen `existing` as its first listing.
    func watch(_ existing: [DownloadEntry] = [DownloadEntry(name: "old.pdf", inode: 1, size: 500)]) -> DownloadWatch {
        var watch = DownloadWatch()
        #expect(watch.update(existing).isEmpty)
        return watch
    }

    let old = DownloadEntry(name: "old.pdf", inode: 1, size: 500)

    @Test func temporaryNames() {
        #expect(DownloadWatch.isTemporary("report.pdf.crdownload"))
        #expect(DownloadWatch.isTemporary("Unconfirmed 123456.crdownload"))
        #expect(DownloadWatch.isTemporary("movie.mkv.PART"))
        #expect(DownloadWatch.isTemporary("app.dmg.download"))
        #expect(DownloadWatch.isTemporary("setup.exe.opdownload"))
        #expect(!DownloadWatch.isTemporary("report.pdf"))
        #expect(!DownloadWatch.isTemporary(".part"))
        #expect(DownloadWatch.finalName(of: "report.pdf.crdownload") == "report.pdf")
        #expect(DownloadWatch.finalName(of: "report.pdf") == nil)
    }

    @Test func whatWasThereFirstNeverCounts() {
        var watch = DownloadWatch()
        #expect(watch.update([old, DownloadEntry(name: "fresh.zip", inode: 2, size: 10)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "fresh.zip", inode: 2, size: 10)]).isEmpty)
        #expect(!watch.isSettling)
    }

    @Test func chromeRenamesItsTemporaryFile() {
        var watch = watch()
        #expect(watch.update([old, DownloadEntry(name: "Unconfirmed 4711.crdownload", inode: 7, size: 100)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "report.pdf.crdownload", inode: 7, size: 900)]).isEmpty)
        #expect(!watch.isSettling)
        #expect(watch.update([old, DownloadEntry(name: "report.pdf", inode: 7, size: 2000)]) == ["report.pdf"])
        // Once only.
        #expect(watch.update([old, DownloadEntry(name: "report.pdf", inode: 7, size: 2000)]).isEmpty)
    }

    @Test func firefoxMovesItsPartOverThePlaceholder() {
        var watch = watch()
        let placeholder = DownloadEntry(name: "movie.mkv", inode: 8, size: 0)
        #expect(watch.update([old, placeholder, DownloadEntry(name: "movie.mkv.part", inode: 9, size: 4000)]).isEmpty)
        // Waiting for the .part costs no extra listings.
        #expect(!watch.isSettling)
        #expect(watch.update([old, placeholder, DownloadEntry(name: "movie.mkv.part", inode: 9, size: 8000)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "movie.mkv", inode: 9, size: 9000)]) == ["movie.mkv"])
    }

    @Test func safariMovesTheFileOutOfItsBundle() {
        var watch = watch()
        let bundle = DownloadEntry(name: "app.dmg.download", inode: 10, size: 96, isFile: false)
        #expect(watch.update([old, bundle]).isEmpty)
        // The bundle and the file swap in one listing …
        #expect(watch.update([old, DownloadEntry(name: "app.dmg", inode: 11, size: 3000)]) == ["app.dmg"])
        // … or the file comes out first and the bundle goes a moment later.
        var later = self.watch()
        #expect(later.update([old, bundle]).isEmpty)
        #expect(later.update([old, bundle, DownloadEntry(name: "app.dmg", inode: 11, size: 3000)]).isEmpty)
        #expect(later.update([old, DownloadEntry(name: "app.dmg", inode: 11, size: 3000)]) == ["app.dmg"])
    }

    @Test func anyOtherNewFileFinishesOnceItsSizeSettles() {
        var watch = watch()
        #expect(watch.update([old, DownloadEntry(name: "data.csv", inode: 12, size: 100)]).isEmpty)
        #expect(watch.isSettling)
        #expect(watch.update([old, DownloadEntry(name: "data.csv", inode: 12, size: 600)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "data.csv", inode: 12, size: 600)]) == ["data.csv"])
        #expect(!watch.isSettling)
    }

    @Test func anEmptyNewFileIsDropped() {
        var watch = watch()
        #expect(watch.update([old, DownloadEntry(name: "empty.txt", inode: 13, size: 0)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "empty.txt", inode: 13, size: 0)]).isEmpty)
        #expect(!watch.isSettling)
    }

    @Test func hiddenFilesFoldersAndTemporaryFilesNeverCount() {
        var watch = watch()
        let others = [old, DownloadEntry(name: ".DS_Store", inode: 14, size: 6000),
                      DownloadEntry(name: "Unzipped", inode: 15, size: 128, isFile: false),
                      DownloadEntry(name: "big.iso.crdownload", inode: 16, size: 50)]
        #expect(watch.update(others).isEmpty)
        #expect(!watch.isSettling)
        #expect(watch.update(others).isEmpty)
    }

    @Test func aRenameInTheFolderIsNoDownload() {
        var watch = watch()
        #expect(watch.update([DownloadEntry(name: "renamed.pdf", inode: 1, size: 500)]).isEmpty)
        #expect(!watch.isSettling)
    }

    @Test func aFileWrittenUnderAHiddenNameSettlesFirst() {
        var watch = watch()
        #expect(watch.update([old, DownloadEntry(name: ".com.google.Chrome.x1", inode: 17, size: 40)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "photo.jpg", inode: 17, size: 80)]).isEmpty)
        #expect(watch.update([old, DownloadEntry(name: "photo.jpg", inode: 17, size: 80)]) == ["photo.jpg"])
    }

    @Test func aCancelledDownloadFinishesNothing() {
        var watch = watch()
        #expect(watch.update([old, DownloadEntry(name: "big.iso.crdownload", inode: 18, size: 50)]).isEmpty)
        #expect(watch.update([old]).isEmpty)
        #expect(!watch.isSettling)
    }
}
