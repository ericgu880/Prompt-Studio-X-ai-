import Foundation

public enum NativeMessagingError: Error, Equatable, CustomStringConvertible, Sendable {
    case frameTooLarge
    case truncatedFrame
    case invalidFrame

    public var description: String {
        switch self {
        case .frameTooLarge: return "native messaging frame exceeds 1 MiB"
        case .truncatedFrame: return "native messaging frame is truncated"
        case .invalidFrame: return "native messaging frame is invalid"
        }
    }
}

public enum NativeMessagingFramer {
    public static let maxFrameBytes = 1_048_576

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameBytes else { throw NativeMessagingError.frameTooLarge }
        guard UInt64(payload.count) <= UInt64(UInt32.max) else { throw NativeMessagingError.frameTooLarge }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8(length & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 24) & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw NativeMessagingError.truncatedFrame }
        let length = UInt32(frame[frame.startIndex])
            | (UInt32(frame[frame.startIndex + 1]) << 8)
            | (UInt32(frame[frame.startIndex + 2]) << 16)
            | (UInt32(frame[frame.startIndex + 3]) << 24)
        guard length <= maxFrameBytes else { throw NativeMessagingError.frameTooLarge }
        guard frame.count == Int(length) + 4 else { throw NativeMessagingError.invalidFrame }
        return Data(frame.dropFirst(4))
    }

    public static func readFrame(from handle: FileHandle) throws -> Data? {
        guard let firstByte = try handle.read(upToCount: 1), !firstByte.isEmpty else { return nil }
        var header = firstByte
        header.append(try readExactly(3, from: handle))
        let length = UInt32(header[0])
            | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 24)
        guard length <= maxFrameBytes else { throw NativeMessagingError.frameTooLarge }
        return try readExactly(Int(length), from: handle)
    }

    public static func writeFrame(_ payload: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: encode(payload))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw NativeMessagingError.invalidFrame }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw NativeMessagingError.truncatedFrame
            }
            data.append(chunk)
        }
        return data
    }
}
