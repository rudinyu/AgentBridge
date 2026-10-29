import Darwin
import Foundation

/// Opens inert extension descriptor files without following links or reading
/// more than the configured, repository-wide descriptor size limit.
public enum BoundedDescriptorFileReader {
    public static let maximumDescriptorSize = 64 * 1_024

    public static func read(at url: URL, maximumBytes: Int = maximumDescriptorSize) throws -> Data {
        guard (0...maximumDescriptorSize).contains(maximumBytes) else {
            throw AgentBridgeError.invalidInput("Descriptor size limit must be between 0 and 64 KiB.")
        }

        var pathMetadata = stat()
        let pathStatus = url.path.withCString { lstat($0, &pathMetadata) }
        guard pathStatus == 0, (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw invalidDescriptor()
        }
        guard pathMetadata.st_size >= 0, pathMetadata.st_size <= off_t(maximumBytes) else {
            throw oversizedDescriptor()
        }

        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw invalidDescriptor() }
        defer { _ = close(descriptor) }

        var initialMetadata = stat()
        guard fstat(descriptor, &initialMetadata) == 0,
              (initialMetadata.st_mode & S_IFMT) == S_IFREG,
              initialMetadata.st_size >= 0 else {
            throw invalidDescriptor()
        }
        guard initialMetadata.st_size <= off_t(maximumBytes) else {
            throw oversizedDescriptor()
        }

        var data = Data()
        data.reserveCapacity(Int(initialMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(8 * 1_024, maximumBytes + 1))
        while true {
            let readLimit = min(buffer.count, maximumBytes - data.count + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, readLimit)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.invalidInput("Could not read descriptor file safely.")
            }
            if bytesRead == 0 { break }
            guard bytesRead <= maximumBytes - data.count else { throw oversizedDescriptor() }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }

        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              (finalMetadata.st_mode & S_IFMT) == S_IFREG,
              finalMetadata.st_size >= 0 else {
            throw invalidDescriptor()
        }
        guard finalMetadata.st_size <= off_t(maximumBytes) else { throw oversizedDescriptor() }
        guard finalMetadata.st_size == off_t(data.count) else {
            throw AgentBridgeError.invalidInput("Descriptor file changed while it was being read.")
        }
        return data
    }

    private static func invalidDescriptor() -> AgentBridgeError {
        .invalidInput("Descriptor files must be regular, non-symlink files no larger than 64 KiB.")
    }

    private static func oversizedDescriptor() -> AgentBridgeError {
        .invalidInput("Descriptor files must be 64 KiB or smaller.")
    }
}
