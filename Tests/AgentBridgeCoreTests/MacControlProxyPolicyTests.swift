import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class MacControlProxyPolicyTests: XCTestCase {
    func testStatusReportsLockedAndOrdinaryForegroundAppsWithoutDesktopLease() throws {
        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = try MacControlProxyPolicy(ticket: fixture.ticket)
        let backend = MockMacControlBackend(frontmost: "org.agentbridge.app", locked: true, screenRecording: false, accessibility: false)

        _ = try policy.call(name: "mac_status", argumentsJSON: json([:]), invoke: backend.invoke)

        XCTAssertEqual(backend.calls.map(\.name), ["mac_status"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("mac-control-proxy.lease").path))

        backend.frontmostBundleID = "com.apple.securityagent"
        XCTAssertNoThrow(try policy.call(name: "mac_status", argumentsJSON: json([:]), invoke: backend.invoke))
        XCTAssertThrowsError(try policy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: backend.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .statusUnavailable)
        }
        XCTAssertFalse(backend.calls.contains(where: { $0.name == "mac_screenshot" }))

        backend.frontmostBundleID = "unknown"
        XCTAssertNoThrow(try policy.call(name: "mac_status", argumentsJSON: json([:]), invoke: backend.invoke))
        XCTAssertThrowsError(try policy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: backend.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .statusUnavailable)
        }
    }

    func testTargetIsForcedAndDifferentTargetIsRejectedBeforeHelperCall() throws {
        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = try MacControlProxyPolicy(ticket: fixture.ticket)
        let backend = MockMacControlBackend(frontmost: "com.apple.Terminal")

        _ = try policy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: backend.invoke)
        let screenshot = try XCTUnwrap(backend.calls.first(where: { $0.name == "mac_screenshot" }))
        let screenshotArguments = try XCTUnwrap(JSONSerialization.jsonObject(with: screenshot.arguments) as? [String: Any])
        XCTAssertEqual(screenshotArguments["app"] as? String, fixture.targetBundleID)

        let wrongBackend = MockMacControlBackend()
        XCTAssertThrowsError(try policy.call(
            name: "mac_screenshot",
            argumentsJSON: json(["app": "com.example.Other"]),
            invoke: wrongBackend.invoke
        )) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .wrongTarget)
        }
        XCTAssertTrue(wrongBackend.calls.isEmpty)
    }

    func testObserveModeRejectsInputAndLockedOrUnpermittedDesktopActions() throws {
        let observeFixture = try MacPolicyFixture(mode: .observe)
        defer { try? FileManager.default.removeItem(at: observeFixture.root) }
        var observe = try MacControlProxyPolicy(ticket: observeFixture.ticket)
        let untouched = MockMacControlBackend()
        XCTAssertThrowsError(try observe.call(name: "mac_key", argumentsJSON: json(["key": "a"]), invoke: untouched.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .toolNotAllowed)
        }
        XCTAssertTrue(untouched.calls.isEmpty)

        let lockedFixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: lockedFixture.root) }
        var lockedPolicy = try MacControlProxyPolicy(ticket: lockedFixture.ticket)
        let locked = MockMacControlBackend(locked: true)
        XCTAssertThrowsError(try lockedPolicy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: locked.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .screenLocked)
        }
        XCTAssertFalse(locked.calls.contains(where: { $0.name == "mac_screenshot" }))

        let permissionFixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: permissionFixture.root) }
        var permissionPolicy = try MacControlProxyPolicy(ticket: permissionFixture.ticket)
        let noScreenRecording = MockMacControlBackend(screenRecording: false)
        XCTAssertThrowsError(try permissionPolicy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: noScreenRecording.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .screenRecordingUnavailable)
        }
        XCTAssertFalse(noScreenRecording.calls.contains(where: { $0.name == "mac_screenshot" }))

        let noAccessibilityFixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: noAccessibilityFixture.root) }
        var noAccessibilityPolicy = try MacControlProxyPolicy(ticket: noAccessibilityFixture.ticket)
        let noAccessibility = MockMacControlBackend(accessibility: false)
        XCTAssertThrowsError(try noAccessibilityPolicy.call(name: "mac_ui_tree", argumentsJSON: json([:]), invoke: noAccessibility.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .accessibilityUnavailable)
        }
        XCTAssertFalse(noAccessibility.calls.contains(where: { $0.name == "mac_ui_tree" }))
    }

    func testSecureFocusBlocksKeyboardAndDetectableSecureFieldsBlockClicks() throws {
        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = try MacControlProxyPolicy(ticket: fixture.ticket)
        let secureFocus = MockMacControlBackend()
        secureFocus.focusedRole = "AXSecureTextField"
        XCTAssertThrowsError(try policy.call(name: "mac_type_text", argumentsJSON: json(["text": "test"]), invoke: secureFocus.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .focusedFieldUnavailable)
        }
        XCTAssertThrowsError(try policy.call(name: "mac_key", argumentsJSON: json(["key": "a"]), invoke: secureFocus.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .focusedFieldUnavailable)
        }
        XCTAssertFalse(secureFocus.calls.contains(where: { $0.name == "mac_type_text" }))
        XCTAssertFalse(secureFocus.calls.contains(where: { $0.name == "mac_key" }))

        let backend = MockMacControlBackend()
        _ = try policy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: backend.invoke)
        backend.containsSecureField = true
        XCTAssertThrowsError(try policy.call(
            name: "mac_mouse",
            argumentsJSON: json(["action": "click", "x": 10, "y": 10]),
            invoke: backend.invoke
        )) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .focusedFieldUnavailable)
        }
        XCTAssertFalse(backend.calls.contains(where: { $0.name == "mac_mouse" }))
    }

    func testMouseRequiresFreshImageCoordinatesAndUnchangedDisplayTopology() throws {
        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = try MacControlProxyPolicy(ticket: fixture.ticket)
        let backend = MockMacControlBackend(imageWidth: 100, imageHeight: 80, displayWidth: 1440, displayHeight: 900)

        XCTAssertThrowsError(try policy.call(
            name: "mac_mouse",
            argumentsJSON: json(["action": "click", "x": 10, "y": 10]),
            invoke: backend.invoke
        )) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .screenshotRequired)
        }

        _ = try policy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: backend.invoke)
        _ = try policy.call(
            name: "mac_mouse",
            argumentsJSON: json(["action": "click", "x": 99, "y": 79]),
            invoke: backend.invoke
        )
        XCTAssertTrue(backend.calls.contains(where: { $0.name == "mac_mouse" }))

        let changedFixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: changedFixture.root) }
        var changedPolicy = try MacControlProxyPolicy(ticket: changedFixture.ticket)
        let changed = MockMacControlBackend(imageWidth: 100, imageHeight: 80, displayWidth: 1440, displayHeight: 900)
        _ = try changedPolicy.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: changed.invoke)
        changed.displayIdentifier = "different-main-display"
        XCTAssertThrowsError(try changedPolicy.call(
            name: "mac_mouse",
            argumentsJSON: json(["action": "click", "x": 10, "y": 10]),
            invoke: changed.invoke
        )) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .screenshotRequired)
        }
        XCTAssertFalse(changed.calls.contains(where: { $0.name == "mac_mouse" }))
    }

    func testDesktopLeaseIsExclusiveAndReleasedWhenOwnerEnds() throws {
        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var owner: MacControlProxyPolicy? = try MacControlProxyPolicy(ticket: fixture.ticket)
        let ownerBackend = MockMacControlBackend()
        _ = try owner?.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: ownerBackend.invoke)

        var contender = try MacControlProxyPolicy(ticket: fixture.ticket)
        let blockedBackend = MockMacControlBackend()
        XCTAssertThrowsError(try contender.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: blockedBackend.invoke)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .desktopBusy)
        }
        XCTAssertTrue(blockedBackend.calls.isEmpty)

        owner = nil
        let availableBackend = MockMacControlBackend()
        _ = try contender.call(name: "mac_screenshot", argumentsJSON: json([:]), invoke: availableBackend.invoke)
        XCTAssertTrue(availableBackend.calls.contains(where: { $0.name == "mac_screenshot" }))
    }

    func testTargetDenylistIsCaseInsensitiveAndUnknownArgumentsAreRejected() throws {
        let settingsFixture = try MacPolicyFixture(target: "com.apple.SystemSettings")
        defer { try? FileManager.default.removeItem(at: settingsFixture.root) }
        XCTAssertThrowsError(try MacControlProxyPolicy(ticket: settingsFixture.ticket)) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .invalidConfiguration)
        }

        let fixture = try MacPolicyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = try MacControlProxyPolicy(ticket: fixture.ticket)
        let backend = MockMacControlBackend()
        XCTAssertThrowsError(try policy.call(
            name: "mac_screenshot",
            argumentsJSON: json(["unexpected": "value"]),
            invoke: backend.invoke
        )) { error in
            XCTAssertEqual(error as? MacControlProxyPolicyError, .invalidArguments)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
}

private final class MockMacControlBackend {
    struct Call {
        let name: String
        let arguments: Data
    }

    var calls: [Call] = []
    var focusedRole = "AXTextField"
    var containsSecureField = false
    var screenLocked: Bool
    var screenRecording: Bool
    var accessibility: Bool
    var frontmostBundleID: String
    var displayWidth: Int
    var displayHeight: Int
    var displayIdentifier = "main-display"
    let imageWidth: Int
    let imageHeight: Int

    init(
        frontmost: String = "com.example.Other",
        locked: Bool = false,
        screenRecording: Bool = true,
        accessibility: Bool = true,
        imageWidth: Int = 100,
        imageHeight: Int = 80,
        displayWidth: Int = 1_440,
        displayHeight: Int = 900
    ) {
        frontmostBundleID = frontmost
        screenLocked = locked
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    func invoke(_ name: String, _ arguments: Data) throws -> Data {
        calls.append(Call(name: name, arguments: arguments))
        switch name {
        case "mac_status":
            return try textResult([
                "screen_locked": screenLocked,
                "screen_recording": screenRecording,
                "accessibility": accessibility,
                "frontmost_bundle_id": frontmostBundleID,
                "main_display": ["id": displayIdentifier, "width": displayWidth, "height": displayHeight]
            ])
        case "mac_ui_tree":
            let children: [[String: Any]] = containsSecureField ? [["role": "AXSecureTextField", "description": "redacted"]] : []
            return try textResult([
                "app": "com.example.Editor",
                "bundle_id": "com.example.Editor",
                "focused": ["role": focusedRole, "description": "field"],
                "tree": ["role": "AXWindow", "title": "Editor", "children": children],
                "truncated": false
            ])
        case "mac_screenshot":
            let image = Self.pngHeader(width: imageWidth, height: imageHeight)
            return try JSONSerialization.data(withJSONObject: [
                "content": [["type": "image", "data": image.base64EncodedString(), "mimeType": "image/png"]],
                "isError": false
            ], options: [.sortedKeys, .fragmentsAllowed])
        default:
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]], "isError": false], options: [.sortedKeys, .fragmentsAllowed])
        }
    }

    private func textResult(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "isError": false], options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func pngHeader(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        bytes += [UInt8((width >> 24) & 255), UInt8((width >> 16) & 255), UInt8((width >> 8) & 255), UInt8(width & 255)]
        bytes += [UInt8((height >> 24) & 255), UInt8((height >> 16) & 255), UInt8((height >> 8) & 255), UInt8(height & 255)]
        return Data(bytes)
    }
}

private final class MacPolicyFixture {
    var root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    var targetBundleID = ""
    var ticket: MCPProxyTicket!

    init(mode: MacControlAccessMode = .control, target: String = "com.example.Editor") throws {
        root = try makeProxyTestRoot("AgentBridge-MacPolicy")
        targetBundleID = target
        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let configuration = try ActiveMCPConfiguration(
            macControlTargetBundleID: target,
            accessMode: mode,
            helperPath: executable.path,
            helperDigest: executable.digest,
            proxyExecutablePath: executable.path,
            proxyExecutableDigest: executable.digest,
            version: "0.3.10"
        )
        ticket = try MCPProxyTicket(
            sessionID: UUID(),
            extensionID: configuration.extensionID,
            projectID: "mac-policy-test",
            provider: .codex,
            profileID: AccountProfile.defaultID(for: .codex),
            configurationDigest: configuration.configurationDigest,
            reviewedDigest: configuration.configurationDigest,
            serverInspectionDigest: String(repeating: "b", count: 64),
            sessionExtensionFingerprint: String(repeating: "c", count: 64),
            runtimeStoreRootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            cancellationRequestPath: root.appendingPathComponent("cancel.request").path,
            receiptPath: root.appendingPathComponent("receipt.json").path,
            proxyExecutablePath: executable.path,
            proxyExecutableDigest: executable.digest,
            serverExecutablePath: configuration.executablePath,
            serverExecutableDigest: configuration.executableDigest,
            serverArguments: configuration.arguments,
            serverEntrypointPins: configuration.entrypointPins,
            allowedTools: configuration.allowedTools,
            startupTimeoutSeconds: configuration.startupTimeoutSeconds,
            toolTimeoutSeconds: configuration.toolTimeoutSeconds,
            maximumToolCallsPerRun: configuration.maximumToolCallsPerRun,
            maximumToolResponseBytes: configuration.maximumToolResponseBytes,
            maximumTotalToolResponseBytes: configuration.maximumTotalToolResponseBytes,
            launchConfiguration: configuration.launchConfiguration,
            expiresAt: Date().addingTimeInterval(120)
        )
    }
}
