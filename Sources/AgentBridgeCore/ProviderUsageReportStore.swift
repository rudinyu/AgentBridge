import Darwin
import Foundation

/// The latest recognized `/usage` report for each account, so a report read in
/// one place can be shown in another: `agentbridge usage-tui` run in the user's
/// own terminal saves what it read, and the App shows it on the usage card.
/// Only the parsed fields are kept; screen text is never written.
public final class ProviderUsageReportStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let instanceLock = NSLock()
    private static let maximumFileSize = 16 * 1_024
    private static let maximumWindows = 8
    private static let maximumTextLength = 120

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try AuditStore.createPrivateDirectory(self.rootURL, fileManager: fileManager)
    }

    public func save(_ report: ProviderUsageReport) throws {
        guard report.provider != .local, Self.isWellFormed(report) else {
            throw AgentBridgeError.invalidInput("The usage report has no recognized provider fields to save.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report), data.count <= Self.maximumFileSize else {
            throw AgentBridgeError.persistence("Could not encode the usage report.")
        }
        instanceLock.lock()
        defer { instanceLock.unlock() }
        let fileURL = fileURL(provider: report.provider, accountProfileID: report.accountProfileID)
        let temporaryURL = rootURL.appendingPathComponent(".report-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not create a temporary usage report file.") }
        defer {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporaryURL)
        }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(descriptor) == 0 else { throw AgentBridgeError.persistence("Could not write the usage report.") }
        var existing = stat()
        if lstat(fileURL.path, &existing) == 0, (existing.st_mode & S_IFMT) != S_IFREG {
            throw AgentBridgeError.persistence("The usage report file cannot be a symlink or a non-regular file.")
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw AgentBridgeError.persistence("Could not save the usage report.")
        }
    }

    /// The saved report for this account, or nil when there is none or it is not
    /// one this store would have written.
    public func latest(provider: AgentProvider, accountProfileID: UUID) -> ProviderUsageReport? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        let url = fileURL(provider: provider, accountProfileID: accountProfileID)
        guard let data = try? BoundedDescriptorFileReader.read(at: url, maximumBytes: Self.maximumFileSize) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(ProviderUsageReport.self, from: data),
              report.provider == provider,
              report.accountProfileID == accountProfileID,
              Self.isWellFormed(report) else { return nil }
        return report
    }

    private func fileURL(provider: AgentProvider, accountProfileID: UUID) -> URL {
        rootURL.appendingPathComponent("\(provider.rawValue)-\(accountProfileID.uuidString.lowercased()).json")
    }

    private static func isWellFormed(_ report: ProviderUsageReport) -> Bool {
        func isShortText(_ value: String?) -> Bool {
            guard let value else { return true }
            return value.count <= maximumTextLength
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        return report.status == .recognizedFields
            && !report.usageWindows.isEmpty
            && report.usageWindows.count <= maximumWindows
            && [report.accountName, report.plan, report.source].allSatisfy(isShortText)
            && report.usageWindows.allSatisfy { window in
                [window.id, window.label, window.resetText].allSatisfy(isShortText)
                    && window.percentageUsed.map { $0.isFinite && (0...100).contains($0) } ?? true
            }
    }
}
