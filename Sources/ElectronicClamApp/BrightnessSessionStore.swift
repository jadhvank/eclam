import Foundation
import Darwin

protocol BrightnessSessionStoring {
    func load() throws -> BrightnessSnapshot?
    func save(_ snapshot: BrightnessSnapshot) throws
    func clear() throws
}

/// The journal contains only panel identity, brightness values and a capture date.
/// A 0600 temporary file is fsynced and renamed before the first brightness write.
final class BrightnessSessionStore: BrightnessSessionStoring {
    enum StoreError: Error { case invalidJournal, ioFailure(Int32) }
    private struct Envelope: Codable {
        let version: Int
        let snapshot: BrightnessSnapshot
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask)[0]
            .appendingPathComponent("com.jadhvank.eclam", isDirectory: true)
            .appendingPathComponent("brightness-session.json")
    }

    func load() throws -> BrightnessSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 16_384 else {
            throw StoreError.invalidJournal
        }
        let data = try Data(contentsOf: fileURL)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.snapshot.isStructurallyValid else { throw StoreError.invalidJournal }
        return envelope.snapshot
    }

    func save(_ snapshot: BrightnessSnapshot) throws {
        guard snapshot.isStructurallyValid else {
            throw StoreError.invalidJournal
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot))
        let temporary = directory.appendingPathComponent(".brightness-session-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.ioFailure(errno) }
        defer {
            close(fd)
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.ioFailure(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw StoreError.ioFailure(errno) }
        guard rename(temporary.path, fileURL.path) == 0 else { throw StoreError.ioFailure(errno) }
        // Persist the directory entry as well as the file contents before dimming.
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryFD >= 0 else { throw StoreError.ioFailure(errno) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw StoreError.ioFailure(errno) }
    }

    func clear() throws {
        if unlink(fileURL.path) != 0 && errno != ENOENT { throw StoreError.ioFailure(errno) }
    }
}
