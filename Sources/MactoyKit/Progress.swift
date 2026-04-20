import Foundation

public struct ProgressUpdate: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing
        case downloading
        case extracting
        case unmounting
        case writing
        case formatting
        case verifying
        case done
        case failed
    }

    public let phase: Phase
    public let message: String
    public let bytesDone: UInt64?
    public let bytesTotal: UInt64?
    public let timestamp: Date

    public init(phase: Phase, message: String, bytesDone: UInt64? = nil, bytesTotal: UInt64? = nil) {
        self.phase = phase
        self.message = message
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.timestamp = Date()
    }

    public var fraction: Double? {
        guard let done = bytesDone, let total = bytesTotal, total > 0 else { return nil }
        return Double(done) / Double(total)
    }
}

public protocol ProgressSink: Sendable {
    func report(_ update: ProgressUpdate)
}

public struct NDJSONProgressSink: ProgressSink {
    public let handle: FileHandle

    public init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    public func report(_ update: ProgressUpdate) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(update) else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}

public struct CallbackProgressSink: ProgressSink {
    public let callback: @Sendable (ProgressUpdate) -> Void
    public init(_ callback: @escaping @Sendable (ProgressUpdate) -> Void) {
        self.callback = callback
    }
    public func report(_ update: ProgressUpdate) { callback(update) }
}
