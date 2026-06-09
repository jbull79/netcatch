import Foundation
import UniformTypeIdentifiers

/// Turns dropped items into file URLs the (sandboxed) app can actually read and send.
///
/// Real files are used in place. File *promises* and raw image/data drops — e.g. an
/// image dragged from Safari/Preview or a pasted screenshot (which macOS names
/// "PNG image.png" and would otherwise try to write into a forbidden folder like
/// Documents) — are materialized into the app's own container temp, which is always
/// writable under App Sandbox.
enum DropMaterializer {
    static func materialize(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let u = await directFileURL(provider) { urls.append(u) }
            else if let u = await copiedFileRepresentation(provider) { urls.append(u) }
            else if let u = await imageData(provider) { urls.append(u) }
        }
        return urls
    }

    private static func dropDir() -> URL {
        let dir = ArchiveService.tempDirectory()
            .appendingPathComponent("drops/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real, readable file on disk — used in place (no copy), preserving streaming.
    private static func directFileURL(_ p: NSItemProvider) async -> URL? {
        guard p.canLoadObject(ofClass: URL.self) else { return nil }
        let url: URL? = await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
        guard let url, url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// A file promise (or any item with a file representation) — copied into our
    /// container so we own it regardless of where the system would have written it.
    private static func copiedFileRepresentation(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dest = dropDir().appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
                cont.resume(returning: FileManager.default.fileExists(atPath: dest.path) ? dest : nil)
            }
        }
    }

    /// Raw image/PDF data with no backing file — written into our container.
    private static func imageData(_ p: NSItemProvider) async -> URL? {
        let types: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .pdf]
        for type in types where p.hasItemConformingToTypeIdentifier(type.identifier) {
            let data: Data? = await withCheckedContinuation { cont in
                p.loadDataRepresentation(forTypeIdentifier: type.identifier) { d, _ in cont.resume(returning: d) }
            }
            if let data {
                let ext = type.preferredFilenameExtension ?? "dat"
                let dest = dropDir().appendingPathComponent("Image.\(ext)")
                try? data.write(to: dest)
                if FileManager.default.fileExists(atPath: dest.path) { return dest }
            }
        }
        return nil
    }
}
