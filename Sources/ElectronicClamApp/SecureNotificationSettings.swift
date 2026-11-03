import Foundation
import Darwin

/// Write into an exclusively created 0600 file, then atomically publish that inode.
/// No credential bytes ever pass through Data.write(.atomic)'s default-mode temp file.
enum SecureNotificationSettings {
    enum SaveError: Error { case unavailable, writeFailed }

    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var template = Array(directory.appendingPathComponent(".notification-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template) // mkstemp creates mode 0600, independent of umask.
        guard fd >= 0 else { throw SaveError.writeFailed }
        let temporary = String(cString: template)
        defer {
            close(fd)
            unlink(temporary)
        }
        guard fchmod(fd, 0o600) == 0 else { throw SaveError.writeFailed }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SaveError.writeFailed }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary, destination.path) == 0 else {
            throw SaveError.writeFailed
        }
    }
}
