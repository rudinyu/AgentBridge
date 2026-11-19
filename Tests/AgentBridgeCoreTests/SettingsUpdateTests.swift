import Foundation
import XCTest
@testable import AgentBridgeCore

/// `updateSettings` changes only the fields it sets on top of the latest saved
/// settings, so a window or the CLI holding an older copy cannot overwrite what
/// another one saved in the meantime.
final class SettingsUpdateTests: XCTestCase {
    private let externalLocalModel = LocalModelSettings(
        backend: .openAICompatible,
        endpoint: "http://127.0.0.1:8081/v1",
        model: "external-model",
        contextWindowTokens: 32_768,
        maxOutputTokens: 2_048
    )

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-SettingsUpdate-\(UUID().uuidString.lowercased())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAnUpdateKeepsFieldsAnotherInstanceSavedSinceTheCallerRead() throws {
        let root = try makeRoot()
        let first = try BridgeService(store: try AuditStore(rootURL: root))
        let second = try BridgeService(store: try AuditStore(rootURL: root))

        let staleCopy = try first.settings()
        try second.updateSettings { $0.localModel = self.externalLocalModel }

        let saved = try first.updateSettings { $0.defaultProvider = .claude }
        XCTAssertEqual(saved.defaultProvider, .claude)
        XCTAssertEqual(saved.localModel, externalLocalModel)
        XCTAssertEqual(try second.settings(), saved)

        // Replacing everything with the stale copy is what used to happen.
        XCTAssertNotEqual(staleCopy.localModel, externalLocalModel)
    }

    func testAnInvalidUpdateLeavesTheSavedSettingsUnchanged() throws {
        let root = try makeRoot()
        let service = try BridgeService(store: try AuditStore(rootURL: root))
        try service.updateSettings { $0.localModel = self.externalLocalModel }
        let before = try service.settings()

        XCTAssertThrowsError(try service.updateSettings { $0.localModel.endpoint = "http://example.com:8081/v1" })
        XCTAssertThrowsError(try service.updateSettings { _ in throw AgentBridgeError.invalidInput("stop") })
        XCTAssertEqual(try service.settings(), before)
    }

    func testAnUpdateValidatesModelDefaultsLikeASave() throws {
        let root = try makeRoot()
        let service = try BridgeService(store: try AuditStore(rootURL: root))
        XCTAssertThrowsError(try service.updateSettings {
            $0.setModelDefaults(ProviderModelChoice(model: "-bad", reasoningEffort: nil), for: .codex)
        })
        let saved = try service.updateSettings {
            $0.setModelDefaults(ProviderModelChoice(model: "gpt-test", reasoningEffort: "low"), for: .codex)
        }
        XCTAssertEqual(saved.modelDefaults(for: .codex).model, "gpt-test")
        XCTAssertEqual(try service.settings().modelDefaults(for: .codex).reasoningEffort, "low")
    }
}
