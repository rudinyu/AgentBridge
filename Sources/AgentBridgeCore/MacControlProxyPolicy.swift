import CoreFoundation
import Darwin
import Foundation

/// Enforces AgentBridge's reviewed MacControl target, mode, and desktop-state
/// rules at the MCP boundary. The helper still performs its own frontmost app
/// and window-geometry checks before sending input.
struct MacControlProxyPolicy {
    private static let screenshotLifetime: TimeInterval = 8
    private static let authenticationFrontmostBundleIDs: Set<String> = [
        "com.apple.securityagent", "com.apple.loginwindow", "com.apple.passwords",
        "com.apple.keychainaccess", "com.apple.securityauthhost",
        "com.apple.authorizationhost", "com.apple.coreauthd", "com.apple.authkituiagent"
    ]
    private static let deniedTargetBundleIDs: Set<String> = [
        "org.agentbridge.app", "tw.com.eaman.maccontrol", "com.apple.systempreferences",
        "com.apple.systemsettings", "com.apple.terminal", "com.googlecode.iterm2",
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.wezfurlong.wezterm", "io.alacritty"
    ]

    let targetBundleID: String
    let accessMode: MacControlAccessMode
    private let runtimeStoreRoot: URL
    private var desktopLease: MacControlDesktopLease?
    private var latestScreenshot: ScreenshotState?

    init(ticket: MCPProxyTicket) throws {
        guard let target = ticket.macControlTargetBundleID,
              let mode = ticket.macControlAccessMode,
              Self.isSafeTarget(target),
              ticket.allowedTools == MacControlActionPolicy.allowedToolNames(for: mode) else {
            throw MacControlProxyPolicyError.invalidConfiguration
        }
        targetBundleID = target
        accessMode = mode
        runtimeStoreRoot = URL(fileURLWithPath: ticket.runtimeStoreRootPath, isDirectory: true)
    }

    /// Runs one reviewed helper tool. `invoke` is the same persistent stdio
    /// connection used for the rest of the proxy session, so helper-maintained
    /// screenshot and window state is preserved.
    mutating func call(
        name: String,
        argumentsJSON: Data,
        invoke: (String, Data) throws -> Data
    ) throws -> Data {
        guard MacControlActionPolicy.allowedToolNames(for: accessMode).contains(name) else {
            throw MacControlProxyPolicyError.toolNotAllowed
        }
        var arguments = try Self.decodeArguments(argumentsJSON)

        if name == "mac_status" {
            guard arguments.isEmpty else { throw MacControlProxyPolicyError.invalidArguments }
            let result = try invoke(name, argumentsJSON)
            _ = try status(from: result, requireUnlocked: false, requireScreenRecording: false, requireAccessibility: false)
            return result
        }

        try forceTargetApp(in: &arguments)
        try validateToolArguments(name: name, arguments: arguments)
        try requireLease()

        let firstStatus = try readStatus(invoke: invoke)
        try validateReadiness(
            firstStatus,
            requireUnlocked: true,
            requireScreenRecording: name == "mac_screenshot" || name == "mac_mouse",
            requireAccessibility: true
        )
        if name == "mac_screenshot", firstStatus.topology == nil {
            throw MacControlProxyPolicyError.screenshotGeometryUnavailable
        }

        if name == "mac_mouse" {
            try validateMouseCoordinates(arguments, status: firstStatus)
        }

        if name == "mac_type_text" || name == "mac_key" {
            let treeArguments = try JSONSerialization.data(withJSONObject: ["app": targetBundleID], options: [.sortedKeys])
            let tree = try invoke("mac_ui_tree", treeArguments)
            guard let focusedRole = try focusedRole(from: tree),
                  focusedRole.caseInsensitiveCompare("AXSecureTextField") != .orderedSame else {
                throw MacControlProxyPolicyError.focusedFieldUnavailable
            }
            let finalStatus = try readStatus(invoke: invoke)
            try validateReadiness(
                finalStatus,
                requireUnlocked: true,
                requireScreenRecording: false,
                requireAccessibility: true
            )
        }

        if name == "mac_mouse", arguments["action"] as? String != "move" {
            let treeArguments = try JSONSerialization.data(withJSONObject: ["app": targetBundleID], options: [.sortedKeys])
            let tree = try invoke("mac_ui_tree", treeArguments)
            let hasSecureField = try containsSecureField(from: tree)
            guard !hasSecureField else {
                throw MacControlProxyPolicyError.focusedFieldUnavailable
            }
            let finalStatus = try readStatus(invoke: invoke)
            try validateReadiness(
                finalStatus,
                requireUnlocked: true,
                requireScreenRecording: false,
                requireAccessibility: true
            )
        }

        let callArguments = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed])
        let result = try invoke(name, callArguments)
        if name == "mac_screenshot" {
            guard let displayTopology = firstStatus.topology,
                  let imageGeometry = try screenshotGeometry(from: result) else {
                latestScreenshot = nil
                throw MacControlProxyPolicyError.screenshotGeometryUnavailable
            }
            latestScreenshot = ScreenshotState(imageGeometry: imageGeometry, displayTopology: displayTopology, capturedAt: Date())
        }
        return result
    }

    private mutating func requireLease() throws {
        if desktopLease != nil { return }
        desktopLease = try MacControlDesktopLease.acquire(rootURL: runtimeStoreRoot)
    }

    private func forceTargetApp(in arguments: inout [String: Any]) throws {
        guard let supplied = arguments["app"] else {
            arguments["app"] = targetBundleID
            return
        }
        guard let supplied = supplied as? String,
              supplied.caseInsensitiveCompare(targetBundleID) == .orderedSame else {
            throw MacControlProxyPolicyError.wrongTarget
        }
        arguments["app"] = targetBundleID
    }

    private func validateToolArguments(name: String, arguments: [String: Any]) throws {
        let allowedKeys: Set<String>
        switch name {
        case "mac_screenshot":
            allowedKeys = ["app"]
        case "mac_ui_tree":
            allowedKeys = ["app", "max_depth"]
            if let depth = arguments["max_depth"] {
                guard let value = Self.finiteNumber(depth), value.rounded(.towardZero) == value, (0...12).contains(value) else {
                    throw MacControlProxyPolicyError.invalidArguments
                }
            }
        case "mac_mouse":
            allowedKeys = ["app", "action", "x", "y", "to_x", "to_y"]
            guard let action = arguments["action"] as? String,
                  ["move", "click", "double_click", "right_click", "drag"].contains(action),
                  let x = arguments["x"], let y = arguments["y"],
                  Self.finiteNumber(x) != nil, Self.finiteNumber(y) != nil else {
                throw MacControlProxyPolicyError.invalidArguments
            }
            let hasToX = arguments["to_x"] != nil
            let hasToY = arguments["to_y"] != nil
            if action == "drag" {
                guard hasToX, hasToY,
                      Self.finiteNumber(arguments["to_x"]!) != nil,
                      Self.finiteNumber(arguments["to_y"]!) != nil else {
                    throw MacControlProxyPolicyError.invalidArguments
                }
            } else if hasToX || hasToY {
                throw MacControlProxyPolicyError.invalidArguments
            }
        case "mac_key":
            allowedKeys = ["app", "key", "modifiers"]
            guard let key = arguments["key"] as? String,
                  !key.isEmpty, key.utf8.count <= 64,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MacControlProxyPolicyError.invalidArguments
            }
            if let rawModifiers = arguments["modifiers"] {
                guard let modifiers = rawModifiers as? [String], Set(modifiers).count == modifiers.count,
                      modifiers.allSatisfy(["cmd", "shift", "alt", "ctrl"].contains) else {
                    throw MacControlProxyPolicyError.invalidArguments
                }
            }
        case "mac_type_text":
            allowedKeys = ["app", "text"]
            guard let text = arguments["text"] as? String, text.count <= 2_000,
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
                  }) else {
                throw MacControlProxyPolicyError.invalidArguments
            }
        case "mac_scroll":
            allowedKeys = ["app", "horizontal", "vertical"]
            let horizontal = arguments["horizontal"].flatMap(Self.finiteNumber)
            let vertical = arguments["vertical"].flatMap(Self.finiteNumber)
            guard (arguments["horizontal"] == nil || horizontal != nil),
                  (arguments["vertical"] == nil || vertical != nil),
                  horizontal != nil || vertical != nil,
                  horizontal.map({ abs($0) <= 1_000 }) ?? true,
                  vertical.map({ abs($0) <= 1_000 }) ?? true else {
                throw MacControlProxyPolicyError.invalidArguments
            }
        default:
            throw MacControlProxyPolicyError.toolNotAllowed
        }
        guard Set(arguments.keys).isSubset(of: allowedKeys) else {
            throw MacControlProxyPolicyError.invalidArguments
        }
    }

    private func validateMouseCoordinates(_ arguments: [String: Any], status: DesktopStatus) throws {
        guard let screenshot = latestScreenshot,
              Date().timeIntervalSince(screenshot.capturedAt) <= Self.screenshotLifetime,
              let currentTopology = status.topology,
              currentTopology == screenshot.displayTopology,
              let x = arguments["x"].flatMap(Self.finiteNumber),
              let y = arguments["y"].flatMap(Self.finiteNumber),
              screenshot.imageGeometry.contains(x: x, y: y) else {
            throw MacControlProxyPolicyError.screenshotRequired
        }
        if let toX = arguments["to_x"].flatMap(Self.finiteNumber),
           let toY = arguments["to_y"].flatMap(Self.finiteNumber),
           !screenshot.imageGeometry.contains(x: toX, y: toY) {
            throw MacControlProxyPolicyError.invalidArguments
        }
    }

    private func readStatus(invoke: (String, Data) throws -> Data) throws -> DesktopStatus {
        let data = try invoke("mac_status", Data("{}".utf8))
        let status = try status(from: data, requireUnlocked: false, requireScreenRecording: false, requireAccessibility: false)
        guard Self.isValidBundleID(status.frontmostBundleID),
              status.frontmostBundleID.caseInsensitiveCompare("unknown") != .orderedSame,
              !Self.authenticationFrontmostBundleIDs.contains(status.frontmostBundleID.lowercased()) else {
            throw MacControlProxyPolicyError.statusUnavailable
        }
        return status
    }

    private func status(
        from resultData: Data,
        requireUnlocked: Bool,
        requireScreenRecording: Bool,
        requireAccessibility: Bool
    ) throws -> DesktopStatus {
        guard let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any],
              result["isError"] as? Bool != true,
              let value = Self.statusObject(from: result),
              let locked = Self.bool(value["screen_locked"]),
              let screenRecording = Self.bool(value["screen_recording"]),
              let accessibility = Self.bool(value["accessibility"]) else {
            throw MacControlProxyPolicyError.statusUnavailable
        }
        let frontmost = value["frontmost_bundle_id"] as? String ?? "unknown"
        let status = DesktopStatus(
            screenLocked: locked,
            screenRecording: screenRecording,
            accessibility: accessibility,
            frontmostBundleID: frontmost,
            topology: Self.topology(from: value)
        )
        try validateReadiness(
            status,
            requireUnlocked: requireUnlocked,
            requireScreenRecording: requireScreenRecording,
            requireAccessibility: requireAccessibility
        )
        return status
    }

    private func validateReadiness(
        _ status: DesktopStatus,
        requireUnlocked: Bool,
        requireScreenRecording: Bool,
        requireAccessibility: Bool
    ) throws {
        if requireUnlocked && status.screenLocked { throw MacControlProxyPolicyError.screenLocked }
        if requireScreenRecording && !status.screenRecording { throw MacControlProxyPolicyError.screenRecordingUnavailable }
        if requireAccessibility && !status.accessibility { throw MacControlProxyPolicyError.accessibilityUnavailable }
    }

    private static func statusObject(from result: [String: Any]) -> [String: Any]? {
        if result["screen_locked"] != nil { return result }
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["screen_locked"] != nil else { continue }
            return value
        }
        return nil
    }

    private func focusedRole(from resultData: Data) throws -> String? {
        guard let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any],
              result["isError"] as? Bool != true,
              let content = result["content"] as? [[String: Any]] else {
            throw MacControlProxyPolicyError.accessibilityUnavailable
        }
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  let data = text.data(using: .utf8),
                  let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let focused = tree["focused"] as? [String: Any] {
                return focused["role"] as? String
            }
            if tree["focused"] is NSNull { return nil }
        }
        throw MacControlProxyPolicyError.accessibilityUnavailable
    }

    private func containsSecureField(from resultData: Data) throws -> Bool {
        guard let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any],
              result["isError"] as? Bool != true,
              let content = result["content"] as? [[String: Any]] else {
            throw MacControlProxyPolicyError.accessibilityUnavailable
        }
        var foundTree = false
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  let data = text.data(using: .utf8),
                  let tree = try? JSONSerialization.jsonObject(with: data) else { continue }
            foundTree = true
            if let object = tree as? [String: Any], object["truncated"] as? Bool == true { return true }
            if Self.containsSecureFieldValue(tree) { return true }
        }
        if foundTree { return false }
        throw MacControlProxyPolicyError.accessibilityUnavailable
    }

    private static func containsSecureFieldValue(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let role = dictionary["role"] as? String,
               role.caseInsensitiveCompare("AXSecureTextField") == .orderedSame { return true }
            return dictionary.values.contains(where: containsSecureFieldValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsSecureFieldValue)
        }
        return false
    }

    private func screenshotGeometry(from resultData: Data) throws -> DisplayGeometry? {
        guard let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any],
              result["isError"] as? Bool != true,
              let content = result["content"] as? [[String: Any]] else {
            throw MacControlProxyPolicyError.screenshotGeometryUnavailable
        }
        for block in content where block["type"] as? String == "image" {
            guard let base64 = block["data"] as? String,
                  let bytes = Data(base64Encoded: base64),
                  bytes.count <= MacControlActionPolicy.maximumToolResponseBytes else { continue }
            if let geometry = Self.imageGeometry(bytes) { return geometry }
        }
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let geometry = Self.geometry(from: object) else { continue }
            return geometry
        }
        return nil
    }

    private static func decodeArguments(_ data: Data) throws -> [String: Any] {
        guard data.count <= 64 * 1_024,
              let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw MacControlProxyPolicyError.invalidArguments
        }
        return value
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isSafeTarget(_ bundleID: String) -> Bool {
        guard MacControlActionPolicy.isAllowedTarget(bundleID) else { return false }
        let normalized = bundleID.lowercased()
        return !deniedTargetBundleIDs.contains(normalized)
            && !authenticationFrontmostBundleIDs.contains(normalized)
    }

    private static func isValidBundleID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (3...255).contains(bytes.count)
            && bytes.contains(46)
            && bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 || $0 == 95 }
            && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..")
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func geometry(from value: [String: Any]) -> DisplayGeometry? {
        let candidates: [[String: Any]] = [
            value["main_display"] as? [String: Any] ?? [:],
            value["display"] as? [String: Any] ?? [:],
            value["main_display_geometry"] as? [String: Any] ?? [:],
            value
        ]
        let keyPairs = [("width", "height"), ("display_width", "display_height"), ("screen_width", "screen_height"), ("main_display_width", "main_display_height"), ("pixel_width", "pixel_height")]
        for candidate in candidates {
            for (widthKey, heightKey) in keyPairs {
                guard let width = finiteNumber(candidate[widthKey]),
                      let height = finiteNumber(candidate[heightKey]),
                      width.rounded(.towardZero) == width,
                      height.rounded(.towardZero) == height,
                      width > 0, height > 0,
                      width <= 100_000, height <= 100_000 else { continue }
                return DisplayGeometry(width: Int(width), height: Int(height))
            }
        }
        return nil
    }

    private static func topology(from value: [String: Any]) -> DisplayTopology? {
        let candidates: [[String: Any]] = [
            value["main_display"] as? [String: Any] ?? [:],
            value["display"] as? [String: Any] ?? [:],
            value["main_display_geometry"] as? [String: Any] ?? [:],
            value
        ]
        for candidate in candidates {
            guard let size = geometry(from: candidate) else { continue }
            let origin = candidate["origin"] as? [String: Any]
            let identifier = (candidate["id"] as? String)
                ?? (candidate["display_id"] as? String)
                ?? (value["main_display_id"] as? String)
                ?? (value["display_id"] as? String)
            let scale = finiteNumber(candidate["scale"])
                ?? finiteNumber(candidate["backing_scale_factor"])
                ?? finiteNumber(value["backing_scale_factor"])
            return DisplayTopology(
                width: size.width,
                height: size.height,
                identifier: identifier,
                originX: finiteNumber(candidate["x"]) ?? finiteNumber(candidate["left"]) ?? finiteNumber(origin?["x"]),
                originY: finiteNumber(candidate["y"]) ?? finiteNumber(candidate["top"]) ?? finiteNumber(origin?["y"]),
                scale: scale
            )
        }
        return nil
    }

    private static func imageGeometry(_ data: Data) -> DisplayGeometry? {
        let bytes = [UInt8](data.prefix(512 * 1_024))
        if bytes.count >= 24,
           Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
           String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" {
            let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
            let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
            return (1...100_000).contains(width) && (1...100_000).contains(height)
                ? DisplayGeometry(width: width, height: height) : nil
        }
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xff else { index += 1; continue }
            let marker = bytes[index + 1]
            index += 2
            if marker == 0xd8 || marker == 0xd9 || (0xd0...0xd7).contains(marker) { continue }
            guard index + 1 < bytes.count else { break }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else { break }
            if [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].contains(marker), length >= 7 {
                let height = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
                let width = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                return (1...100_000).contains(width) && (1...100_000).contains(height)
                    ? DisplayGeometry(width: width, height: height) : nil
            }
            index += length
        }
        return nil
    }

    private struct DesktopStatus {
        let screenLocked: Bool
        let screenRecording: Bool
        let accessibility: Bool
        let frontmostBundleID: String
        let topology: DisplayTopology?
    }

    private struct ScreenshotState {
        let imageGeometry: DisplayGeometry
        let displayTopology: DisplayTopology
        let capturedAt: Date
    }
}

private struct DisplayGeometry: Equatable {
    let width: Int
    let height: Int

    func contains(x: Double, y: Double) -> Bool {
        x >= 0 && y >= 0 && x < Double(width) && y < Double(height)
    }
}

private struct DisplayTopology: Equatable {
    let width: Int
    let height: Int
    let identifier: String?
    let originX: Double?
    let originY: Double?
    let scale: Double?
}

enum MacControlProxyPolicyError: Error, LocalizedError, Equatable {
    case invalidConfiguration
    case toolNotAllowed
    case wrongTarget
    case invalidArguments
    case statusUnavailable
    case screenLocked
    case screenRecordingUnavailable
    case accessibilityUnavailable
    case focusedFieldUnavailable
    case screenshotRequired
    case screenshotGeometryUnavailable
    case desktopBusy

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The reviewed MacControl policy is invalid."
        case .toolNotAllowed: "The requested MacControl action is not allowed by this preset."
        case .wrongTarget: "The requested app does not match the reviewed MacControl target."
        case .invalidArguments: "The MacControl arguments are invalid or outside the supported bounds."
        case .statusUnavailable: "MacControl could not confirm a safe desktop state."
        case .screenLocked: "The Mac is locked; desktop control is unavailable."
        case .screenRecordingUnavailable: "Screen Recording permission is unavailable."
        case .accessibilityUnavailable: "Accessibility permission or focused UI state is unavailable."
        case .focusedFieldUnavailable: "Text input was refused because the focused field could not be confirmed safe."
        case .screenshotRequired: "Take a fresh screenshot before sending mouse input."
        case .screenshotGeometryUnavailable: "The screenshot does not match the current main-display coordinate space."
        case .desktopBusy: "Another AgentBridge MacControl proxy currently owns the desktop."
        }
    }
}

private final class MacControlDesktopLease {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(rootURL: URL) throws -> MacControlDesktopLease {
        do {
            let descriptor = try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { rootDescriptor -> Int32 in
                let fd = "mac-control-proxy.lease".withCString {
                    openat(rootDescriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
                }
                guard fd >= 0 else { throw MacControlProxyPolicyError.desktopBusy }
                var metadata = stat()
                guard fstat(fd, &metadata) == 0,
                      (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      metadata.st_uid == getuid(), metadata.st_nlink == 1,
                      fchmod(fd, mode_t(0o600)) == 0 else {
                    _ = Darwin.close(fd)
                    throw MacControlProxyPolicyError.desktopBusy
                }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    _ = Darwin.close(fd)
                    throw MacControlProxyPolicyError.desktopBusy
                }
                return fd
            }
            return MacControlDesktopLease(descriptor: descriptor)
        } catch let error as MacControlProxyPolicyError {
            throw error
        } catch {
            throw MacControlProxyPolicyError.desktopBusy
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}
