import AppKit
import NotchCore
import UniformTypeIdentifiers

/// Files dropped on Tara or the shelf: a file from Finder comes as its URL; one a browser only
/// promises (a Gmail attachment dragged out of Chrome) is written to a copy in the brain folder
/// first, which the next launch clears away. Either way the original is only read.
enum FileDrop {
    /// What a drop target accepts: files, and promised files of any data type.
    static let types: [UTType] = [.fileURL, .data]

    /// Pasteboard types of a promised file (on top of plain file URLs) while a drag is under way.
    static let promiseTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
    ]

    /// Calls `found` on the main actor with the first file of the drop; false when there is none.
    @discardableResult
    static func load(_ providers: [NSItemProvider], found: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in found(url) }
            }
            return true
        }
        // A promised file's own type (a PDF, a picture): not a link or a piece of text, which a
        // browser drag carries too (Chrome's Gmail attachment brings its URL along).
        guard let type = provider.registeredTypeIdentifiers.first(where: { id in
            guard let type = UTType(id) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text)
        }) else { return false }
        let name = provider.suggestedName
        provider.loadFileRepresentation(forTypeIdentifier: type) { temporary, _ in
            // The temporary file is gone once this returns: keep a copy of it.
            guard let temporary else { return }
            let folder = Brand.supportFolder.appending(path: "brain")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = temporary.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "") : temporary.pathExtension
            let base = (name ?? temporary.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "/", with: "-")
            let copy = folder.appending(path: AskWindowShot.prefix + "drop-" + UUID().uuidString.prefix(8))
                .appending(path: ext.isEmpty || base.hasSuffix("." + ext) ? base : base + "." + ext)
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporary, to: copy)
            } catch {
                return
            }
            Task { @MainActor in found(copy) }
        }
        return true
    }
}
