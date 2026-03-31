import Foundation

public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    public init(path: String, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    public func start() {
        stop()
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            self.handler()

            if flags.contains(.delete) || flags.contains(.rename) {
                self.stop()
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start()
                }
            }
        }

        src.setCancelHandler { [fd = fileDescriptor] in
            close(fd)
        }

        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    deinit {
        stop()
    }
}
