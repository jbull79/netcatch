import Foundation
import AppleArchive
import System

/// The bytes we will actually transmit for one item, plus the metadata describing it.
struct PreparedItem {
    var item: TransferItem
    var blobURL: URL          // file containing the exact bytes to send
    var blobIsTemporary: Bool // delete after sending
}

/// Builds transmit blobs (archive folders, smart-compress files) and reverses them
/// on receive. 100% native (AppleArchive + Foundation compression).
enum ArchiveService {
    /// Extensions whose contents are already compressed — never worth re-compressing.
    private static let incompressibleExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp",
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "mp3", "aac", "m4a", "flac", "ogg", "opus",
        "zip", "gz", "bz2", "xz", "7z", "rar", "zst",
        "pdf", "docx", "xlsx", "pptx", "dmg", "pkg"
    ]

    /// Slack allowed above the claimed original size when decompressing, before we
    /// treat the stream as a decompression bomb and abort.
    private static let decompressionSlack: Int64 = 1 << 20      // 1 MB
    private static let streamBufferSize = 1 << 20               // 1 MB I/O buffer

    static func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetCatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Prepare (send side)

    static func prepare(url: URL, compressRequested: Bool) throws -> PreparedItem {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            return try prepareDirectory(url, compress: compressRequested)
        } else {
            return try prepareFile(url, compressRequested: compressRequested)
        }
    }

    private static func prepareDirectory(_ url: URL, compress: Bool) throws -> PreparedItem {
        let originalSize = directorySize(url)
        let blobURL = tempDirectory().appendingPathComponent(UUID().uuidString + ".aar")
        try archiveDirectory(url, to: blobURL, compress: compress)
        let transmitted = fileSize(blobURL)
        let item = TransferItem(
            name: url.lastPathComponent,
            originalSize: originalSize,
            transmittedSize: transmitted,
            isDirectory: true,
            compressed: compress,
            sha256: try CryptoService.sha256Hex(ofFileAt: blobURL)
        )
        return PreparedItem(item: item, blobURL: blobURL, blobIsTemporary: true)
    }

    private static func prepareFile(_ url: URL, compressRequested: Bool) throws -> PreparedItem {
        let originalSize = fileSize(url)
        let ext = url.pathExtension.lowercased()
        let worthCompressing = compressRequested
            && !incompressibleExtensions.contains(ext)
            && originalSize > 0

        if worthCompressing {
            // Stream-compress to a temp blob (no full-file in-memory load, so this
            // works for arbitrarily large files). Keep it only if it actually shrank.
            let blobURL = tempDirectory().appendingPathComponent(UUID().uuidString + ".lzfse")
            try compressFileStream(url, to: blobURL)
            let compressedSize = fileSize(blobURL)
            if compressedSize > 0 && compressedSize < originalSize {
                let item = TransferItem(
                    name: url.lastPathComponent,
                    originalSize: originalSize,
                    transmittedSize: compressedSize,
                    isDirectory: false,
                    compressed: true,
                    sha256: try CryptoService.sha256Hex(ofFileAt: blobURL)
                )
                return PreparedItem(item: item, blobURL: blobURL, blobIsTemporary: true)
            }
            try? FileManager.default.removeItem(at: blobURL)   // no benefit — send raw
        }

        // Send the file as-is (no benefit or compression disabled).
        let item = TransferItem(
            name: url.lastPathComponent,
            originalSize: originalSize,
            transmittedSize: originalSize,
            isDirectory: false,
            compressed: false,
            sha256: try CryptoService.sha256Hex(ofFileAt: url)
        )
        return PreparedItem(item: item, blobURL: url, blobIsTemporary: false)
    }

    // MARK: Reconstruct (receive side)

    /// Turn a received blob back into the final file or folder at `destination`.
    static func reconstruct(item: TransferItem, blobURL: URL, to destination: URL) throws {
        if item.isDirectory {
            // Extract into a confined staging dir first, verify no entry escapes it
            // (zip-slip / malicious symlinks), then move the verified tree into place.
            let staging = tempDirectory().appendingPathComponent("extract-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try extractArchive(blobURL, to: staging, compressed: item.compressed)
            try validateNoEscape(root: staging)
            // Reject a decompression bomb: extracted size must be near the claimed original.
            guard directorySize(staging) <= item.originalSize + decompressionSlack else {
                throw ArchiveError.tooLarge
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } else if item.compressed {
            // Stream-decompress with a hard output cap so a small blob can't inflate
            // into an unbounded file (decompression bomb).
            try decompressFileStream(blobURL, to: destination,
                                     maxOutput: item.originalSize + decompressionSlack)
        } else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: blobURL, to: destination)
        }
    }

    // MARK: Single-file streaming (de)compression

    /// LZFSE-compress `src` to `dest`, streaming through a fixed buffer so memory
    /// stays flat regardless of file size.
    static func compressFileStream(_ src: URL, to dest: URL) throws {
        guard let writeStream = ArchiveByteStream.fileStream(
                path: FilePath(dest.path), mode: .writeOnly,
                options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)),
              let compress = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream),
              let readStream = ArchiveByteStream.fileStream(
                path: FilePath(src.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o644))
        else { throw ArchiveError.streamFailed }
        // Close compress before writeStream so the final compressed bytes flush.
        defer { try? readStream.close(); try? compress.close(); try? writeStream.close() }
        _ = try ArchiveByteStream.process(readingFrom: readStream, writingTo: compress)
    }

    /// Stream-decompress `src` into `dest`, aborting if output exceeds `maxOutput`
    /// (decompression-bomb guard). Never holds the whole file in memory.
    static func decompressFileStream(_ src: URL, to dest: URL, maxOutput: Int64) throws {
        guard let readStream = ArchiveByteStream.fileStream(
                path: FilePath(src.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: readStream)
        else { throw ArchiveError.streamFailed }
        defer { try? decompress.close(); try? readStream.close() }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        var buffer = [UInt8](repeating: 0, count: streamBufferSize)
        var total: Int64 = 0
        while true {
            let n = try buffer.withUnsafeMutableBytes { raw in
                try decompress.read(into: raw)
            }
            if n == 0 { break }
            total += Int64(n)
            if total > maxOutput { throw ArchiveError.tooLarge }
            out.write(Data(bytes: buffer, count: n))
        }
    }

    // MARK: AppleArchive directory streams

    private static func archiveDirectory(_ source: URL, to dest: URL, compress: Bool) throws {
        let compression: ArchiveCompression = compress ? .lzfse : .none
        guard let writeStream = ArchiveByteStream.fileStream(
            path: FilePath(dest.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)) else { throw ArchiveError.streamFailed }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(using: compression, writingTo: writeStream) else {
            throw ArchiveError.streamFailed
        }
        defer { try? compressStream.close() }

        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
            throw ArchiveError.streamFailed
        }
        defer { try? encodeStream.close() }

        guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM") else {
            throw ArchiveError.streamFailed
        }
        try encodeStream.writeDirectoryContents(archiveFrom: FilePath(source.path), keySet: keySet)
    }

    private static func extractArchive(_ source: URL, to destDir: URL, compressed: Bool) throws {
        guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(source.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)) else { throw ArchiveError.streamFailed }
        defer { try? readStream.close() }

        let decodeSource: ArchiveByteStream
        let decompressStream: ArchiveByteStream?
        if compressed {
            guard let d = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
                throw ArchiveError.streamFailed
            }
            decompressStream = d
            decodeSource = d
        } else {
            decompressStream = nil
            decodeSource = readStream
        }
        defer { try? decompressStream?.close() }

        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decodeSource) else {
            throw ArchiveError.streamFailed
        }
        defer { try? decodeStream.close() }

        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(destDir.path),
            flags: [.ignoreOperationNotPermitted]) else { throw ArchiveError.streamFailed }
        defer { try? extractStream.close() }

        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }

    // MARK: Sizes

    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Reject an extracted tree if any entry (or symlink target) resolves outside
    /// `root` — guards against zip-slip path traversal and symlink escapes from a
    /// malicious archive.
    private static func validateNoEscape(root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        func inside(_ path: String) -> Bool { path == rootPath || path.hasPrefix(prefix) }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isSymbolicLinkKey],
                                             options: []) else { return }
        for case let url as URL in enumerator {
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            if isSymlink {
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                    .standardizedFileURL.resolvingSymlinksInPath().path
                if !inside(resolved) { throw ArchiveError.unsafeEntry }
            } else if !inside(url.resolvingSymlinksInPath().standardizedFileURL.path) {
                throw ArchiveError.unsafeEntry
            }
        }
    }

    enum ArchiveError: Error { case streamFailed, unsafeEntry, tooLarge }
}
