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

    private static let maxInMemoryCompression: Int64 = 200 * 1024 * 1024

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
            && originalSize <= maxInMemoryCompression

        if worthCompressing {
            let raw = try Data(contentsOf: url)
            if let compressed = try? (raw as NSData).compressed(using: .lzfse) as Data,
               compressed.count < raw.count {
                let blobURL = tempDirectory().appendingPathComponent(UUID().uuidString + ".lzfse")
                try compressed.write(to: blobURL)
                let item = TransferItem(
                    name: url.lastPathComponent,
                    originalSize: originalSize,
                    transmittedSize: Int64(compressed.count),
                    isDirectory: false,
                    compressed: true,
                    sha256: CryptoService.sha256Hex(of: compressed)
                )
                return PreparedItem(item: item, blobURL: blobURL, blobIsTemporary: true)
            }
        }

        // Send the file as-is (no benefit, too big, or compression disabled).
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
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try extractArchive(blobURL, to: destination, compressed: item.compressed)
        } else if item.compressed {
            let compressed = try Data(contentsOf: blobURL)
            let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
            try raw.write(to: destination)
        } else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: blobURL, to: destination)
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

    enum ArchiveError: Error { case streamFailed }
}
