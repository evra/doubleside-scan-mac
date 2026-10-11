import Foundation

/// libscanline reports progress only via print(); tee stdout so the UI can show it.
final class StdoutTap: @unchecked Sendable {
    static let shared = StdoutTap()

    private let lock = NSLock()
    private var pipe: Pipe?
    private var buffer = Data()
    private var echo = true
    private var handler: (@MainActor (String) -> Void)?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard pipe == nil else { return }
        let pipe = Pipe()
        let original = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            if echo { data.withUnsafeBytes { _ = write(original, $0.baseAddress, $0.count) } }
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 10) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
            }
            let handler = handler
            lock.unlock()
            if let handler, !lines.isEmpty {
                Task { @MainActor in lines.forEach(handler) }
            }
        }
        self.pipe = pipe
    }

    func observe(echo: Bool, _ handler: (@MainActor (String) -> Void)?) {
        lock.lock()
        self.echo = echo
        self.handler = handler
        lock.unlock()
    }
}
