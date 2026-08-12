import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum NativeMessagingError: Error, Equatable, CustomStringConvertible, Sendable {
    case frameTooLarge
    case truncatedFrame
    case invalidFrame
    case deadlineExceeded

    public var description: String {
        switch self {
        case .frameTooLarge: return "native messaging frame exceeds 1 MiB"
        case .truncatedFrame: return "native messaging frame is truncated"
        case .invalidFrame: return "native messaging frame is invalid"
        case .deadlineExceeded: return "native messaging frame deadline exceeded"
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

    public static func readFrame(from handle: FileHandle, deadline: Date) throws -> Data? {
        guard let firstByte = try readFirstByte(from: handle, deadline: deadline) else { return nil }
        let header = firstByte + (try readExactly(3, from: handle, deadline: deadline))
        let length = UInt32(header[0])
            | (UInt32(header[1]) << 8)
            | (UInt32(header[2]) << 16)
            | (UInt32(header[3]) << 24)
        guard length <= maxFrameBytes else { throw NativeMessagingError.frameTooLarge }
        return try readExactly(Int(length), from: handle, deadline: deadline)
    }

    public static func writeFrame(_ payload: Data, to handle: FileHandle, deadline: Date) throws {
        let frame = try encode(payload)
        var offset = 0
        while offset < frame.count {
            try waitForIO(handle.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
            let written = frame.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(handle.fileDescriptor, base.advanced(by: offset), frame.count - offset)
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw NativeMessagingError.invalidFrame
            }
            if written == 0 { throw NativeMessagingError.invalidFrame }
            offset += written
        }
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

    private static func readExactly(_ count: Int, from handle: FileHandle, deadline: Date) throws -> Data {
        guard count >= 0 else { throw NativeMessagingError.invalidFrame }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            try waitForIO(handle.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let chunk = try handle.read(upToCount: count - data.count)
            guard let chunk, !chunk.isEmpty else { throw NativeMessagingError.truncatedFrame }
            data.append(chunk)
        }
        return data
    }

    private static func readFirstByte(from handle: FileHandle, deadline: Date) throws -> Data? {
        try waitForIO(handle.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
        guard let firstByte = try handle.read(upToCount: 1), !firstByte.isEmpty else { return nil }
        return firstByte
    }

    private static func waitForIO(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        #if canImport(Darwin)
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw NativeMessagingError.deadlineExceeded }
            let milliseconds = Int32(max(1, min(Double(Int32.max), ceil(remaining * 1_000))))
            let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if result > 0 { return }
            if result == 0 { throw NativeMessagingError.deadlineExceeded }
            if errno != EINTR { throw NativeMessagingError.invalidFrame }
        }
        #else
        throw NativeMessagingError.deadlineExceeded
        #endif
    }
}
