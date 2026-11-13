import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// Removing a chat from the app: confirmation first, then the chat is gone.
@MainActor
final class ChatRemovalFlowTests: XCTestCase {
    func testAChatIsRemovedOnlyAfterConfirmation() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let discussion = try service.createDiscussion(provider: .codex, accountProfileID: AccountProfile.defaultID(for: .codex))
        model.chats.refreshDiscussions()
        model.chats.openDiscussion(discussion.id)

        model.chats.reviewDiscussionRemoval(discussion.id)
        XCTAssertEqual(model.chats.discussionPendingRemoval?.id, discussion.id)
        model.chats.cancelDiscussionRemoval()
        XCTAssertTrue(model.chats.discussions.contains(where: { $0.id == discussion.id }))

        model.chats.reviewDiscussionRemoval(discussion.id)
        model.chats.confirmDiscussionRemoval()
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.chats.discussionPendingRemoval)
        XCTAssertNil(model.chats.selectedDiscussionID)
        XCTAssertFalse(model.chats.discussions.contains(where: { $0.id == discussion.id }))
        XCTAssertEqual(model.status, "Removed the chat. Project sessions made from it are kept.")
    }

    func testTheConfirmationIsInTheAppLanguage() throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let discussion = try service.createDiscussion(provider: .codex, accountProfileID: AccountProfile.defaultID(for: .codex))
        XCTAssertEqual(model.chats.chatRemovalMessage(for: discussion), "This deletes the chat and its 0 turns. It cannot be undone.")
        let previousLanguage = model.appLanguage
        model.appLanguage = .traditionalChinese
        defer { model.appLanguage = previousLanguage }
        XCTAssertEqual(model.chats.chatRemovalMessage(for: discussion), "這會刪除這個聊天和其中的 0 個回合，無法復原。")
    }
}
