import Foundation

protocol NotificationCancellation: AnyObject {
    func cancel()
}

extension URLSessionDataTask: NotificationCancellation {}
extension DispatchWorkItem: NotificationCancellation {}

/// Only the HTTP boundary is injectable; provider policy stays in the notifiers.
protocol NotificationTransport {
    func send(_ request: URLRequest,
              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> NotificationCancellation
}

final class NotificationRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A credential-bearing request must never follow any redirect, even same-host.
        completionHandler(nil)
    }
}

final class URLSessionNotificationTransport: NotificationTransport {
    private let session: URLSession

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return config
    }

    init() {
        session = URLSession(configuration: Self.configuration(),
                             delegate: NotificationRedirectDelegate(), delegateQueue: nil)
    }

    func send(_ request: URLRequest,
              completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> NotificationCancellation {
        let task = session.dataTask(with: request, completionHandler: completion)
        task.resume()
        return task
    }

    deinit { session.invalidateAndCancel() }
}

/// All operation state lives on main. A retry retains the original complete request,
/// and invalidation removes the operation before cancellation can race its completion.
final class NotificationDelivery {
    typealias Completion = (Data?, URLResponse?, Error?) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> NotificationCancellation

    private struct Operation {
        let generation: UInt64
        let request: URLRequest
        let completion: Completion
        var pending: NotificationCancellation?
    }

    private let transport: NotificationTransport
    private let schedule: Scheduler
    private var generation: UInt64 = 0
    private var operations: [UUID: Operation] = [:]
    private(set) var stopped = false

    init(transport: NotificationTransport = URLSessionNotificationTransport(),
         schedule: @escaping Scheduler = NotificationDelivery.scheduleOnMain) {
        self.transport = transport
        self.schedule = schedule
    }

    static func scheduleOnMain(after delay: TimeInterval,
                               action: @escaping () -> Void) -> NotificationCancellation {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    func send(_ request: URLRequest, retryTransportFailure: Bool = false,
              completion: @escaping Completion) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else {
            completion(nil, nil, URLError(.cancelled))
            return
        }
        let id = UUID()
        operations[id] = Operation(generation: generation, request: request,
                                   completion: completion, pending: nil)
        attempt(id, canRetry: retryTransportFailure)
    }

    private func attempt(_ id: UUID, canRetry: Bool) {
        guard let op = operations[id], op.generation == generation, !stopped else { return }
        let pending = transport.send(op.request) { [weak self] data, response, error in
            // Always defer, including synchronous fake transports, so pending is installed first.
            DispatchQueue.main.async {
                guard let self, let current = self.operations[id],
                      current.generation == self.generation, !self.stopped else { return }
                if let error, !Self.isCancellation(error), canRetry {
                    let retry = self.schedule(5) { [weak self] in
                        dispatchPrecondition(condition: .onQueue(.main))
                        self?.attempt(id, canRetry: false)
                    }
                    self.operations[id]?.pending = retry
                    return
                }
                self.operations.removeValue(forKey: id)
                current.completion(data, response, error)
            }
        }
        operations[id]?.pending = pending
    }

    func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        let cancelled = Array(operations.values)
        operations.removeAll()
        for operation in cancelled { operation.pending?.cancel() }
        // Finish UI requests exactly once so controls cannot remain disabled.
        // Notifiers treat cancellation separately from delivery results.
        for operation in cancelled { operation.completion(nil, nil, URLError(.cancelled)) }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true
        invalidate()
    }

    static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// Fixed local messages only: NSError descriptions and server response text may contain credentials.
enum NotificationDiagnostic {
    static func transport(_ error: Error) -> String {
        if NotificationDelivery.isCancellation(error) {
            return NSL("notification.error.cancelled", "Request cancelled because notification settings changed or the app stopped.")
        }
        return NSL("notification.error.transport", "Could not reach the notification service. Check your connection and try again.")
    }

    static var invalidResponse: String {
        NSL("notification.error.response", "The notification service returned an unsuccessful or invalid response.")
    }
}
