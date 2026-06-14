import Darwin
import Dispatch
import Foundation
import OSLog

/// One-directory `DispatchSource.makeFileSystemObjectSource` wrapper.
/// ADR-0006 §K — sub-100ms latency 3rd OR-branch alongside the 5s poll +
/// Darwin notify hook channel.
///
/// Lifecycle:
///   - `init`: open(O_EVTONLY) + DispatchSource + activate.
///   - On `.delete` (directory removed/renamed away): stop the source, schedule
///     a reopen attempt 2s later, repeat until success or `stop()`.
///   - `stop()`: cancel source, close fd. Idempotent.
///
/// Events are coalesced inside a 50ms window so a single transcript write
/// doesn't fan out into multiple `onChange` invocations.
final class FileChangeWatcher {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "fswatch")
    private let directoryURL: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var coalescePending = false
    private var stopped = false

    init(directoryURL: URL, queue: DispatchQueue, onChange: @escaping () -> Void) throws {
        self.directoryURL = directoryURL
        self.queue = queue
        self.onChange = onChange
        try openAndActivate()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            teardownLocked()
        }
    }

    // MARK: - Internals

    private func openAndActivate() throws {
        let path = directoryURL.path
        let opened = path.withCString { open($0, O_EVTONLY) }
        guard opened >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "open(\(path), O_EVTONLY) failed: \(String(cString: strerror(errno)))"])
        }
        self.fd = opened

        let mask: DispatchSource.FileSystemEvent = [.write, .extend, .rename, .delete]
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: mask,
            queue: queue)

        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            let events = s.data
            if events.contains(.delete) || events.contains(.rename) {
                Self.log.info("watcher saw delete/rename on \(self.directoryURL.path, privacy: .public); scheduling reopen")
                self.teardownLocked()
                self.scheduleReopen()
                return
            }
            self.coalesceAndFire()
        }
        s.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        self.source = s
        s.resume()
    }

    private func teardownLocked() {
        if let s = source {
            s.cancel()  // cancel handler closes fd
            source = nil
        } else if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func scheduleReopen() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.stopped else { return }
            // Only attempt if the directory exists now.
            var st = stat()
            guard stat(self.directoryURL.path, &st) == 0 else {
                self.scheduleReopen()
                return
            }
            do {
                try self.openAndActivate()
                // Fire once after a successful reopen — caller may have missed
                // changes during the gap.
                self.onChange()
            } catch {
                Self.log.error("reopen \(self.directoryURL.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public); retrying")
                self.scheduleReopen()
            }
        }
    }

    private func coalesceAndFire() {
        guard !coalescePending else { return }
        coalescePending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self = self else { return }
            self.coalescePending = false
            guard !self.stopped else { return }
            self.onChange()
        }
    }
}
