import Foundation

/// Splits an MJPEG stream (multipart/x-mixed-replace, as mjpeg-streamer and the printers' cameras send it) into
/// JPEG frames. It looks for the JPEG start (FF D8) and end (FF D9) markers, so it doesn't depend on the multipart
/// boundary or headers. Feed it bytes as they arrive; it returns each complete frame and keeps the remainder.
public struct MJPEGSplitter: Sendable {
    private var buffer = Data()
    /// Frames larger than this are dropped (a broken stream shouldn't eat memory).
    public var maxFrameBytes = 8 * 1024 * 1024

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while true {
            guard let start = find(0xD8, from: buffer.startIndex) else {
                // Keep a trailing 0xFF in case the next chunk starts with D8.
                buffer = buffer.last == 0xFF ? Data([0xFF]) : Data()
                break
            }
            guard let end = find(0xD9, from: start + 2) else {
                if start > buffer.startIndex { buffer = Data(buffer[start...]) }
                if buffer.count > maxFrameBytes { buffer = Data() }
                break
            }
            frames.append(Data(buffer[start..<(end + 2)]))
            buffer = Data(buffer[(end + 2)...])
        }
        return frames
    }

    /// Index of the 0xFF in the first "FF <marker>" pair at or after `from`.
    private func find(_ marker: UInt8, from: Data.Index) -> Data.Index? {
        var i = from
        let end = buffer.endIndex
        while i + 1 < end {
            if buffer[i] == 0xFF && buffer[i + 1] == marker { return i }
            i += 1
        }
        return nil
    }
}
