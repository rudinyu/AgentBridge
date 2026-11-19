import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// Local model drafts fill fields only as the user agreed, and the notes say why
/// the existing text was kept.
final class LocalHelperFillTests: XCTestCase {
    private typealias PRFields = LocalHelperFill.PullRequestFields
    private typealias HandoffFields = LocalHelperFill.HandoffFields

    func testPullRequestTextIsReplacedWithoutAskingOnlyWhileItIsTheProposal() {
        let proposed = PRFields(commitMessage: "Title\n\nBody\n", title: "Title", body: "Body\n")
        XCTAssertFalse(LocalHelperFill.pullRequestNeedsConfirmation(current: proposed, proposed: proposed))
        XCTAssertFalse(LocalHelperFill.pullRequestNeedsConfirmation(current: PRFields(commitMessage: " ", title: "", body: "\n"), proposed: proposed))
        var edited = proposed
        edited.title = "My own title"
        XCTAssertTrue(LocalHelperFill.pullRequestNeedsConfirmation(current: edited, proposed: proposed))
        edited = proposed
        edited.body = "Body\nwith a line I added\n"
        XCTAssertTrue(LocalHelperFill.pullRequestNeedsConfirmation(current: edited, proposed: proposed))
    }

    func testHandoffFieldsWithAnyTextNeedAnAnswerFirst() {
        XCTAssertFalse(LocalHelperFill.handoffNeedsConfirmation(current: HandoffFields(done: "", next: " ", prompt: "\n")))
        XCTAssertTrue(LocalHelperFill.handoffNeedsConfirmation(current: HandoffFields(done: "", next: "Write tests", prompt: "")))
    }

    func testDraftsFillEveryField() {
        let text = PullRequestDraftText(commitMessage: "Add a parser\n\nIt reads files.\n", title: "Add a parser", body: "Adds it.\n")
        XCTAssertEqual(LocalHelperFill.fields(for: text), PRFields(commitMessage: "Add a parser\n\nIt reads files.\n", title: "Add a parser", body: "Adds it.\n"))
        let handoff = LocalHelperHandoffDraft(done: "a", next: "b", prompt: "c")
        XCTAssertEqual(LocalHelperFill.fields(for: handoff), HandoffFields(done: "a", next: "b", prompt: "c"))
    }

    func testNotesGiveTheFallbackReasonTruncationAndLongSubject() {
        let preview = LocalHelperPreview(
            task: .commitText,
            files: [],
            sentFileCount: 1,
            parts: [],
            truncationNotes: ["Truncated: only the first 1 of 4 files were sent."],
            budgetBytes: 100,
            prompt: "x"
        )
        let kept = LocalHelperOutcome<PullRequestDraftText>(draft: nil, fallbackReason: "The local model did not answer in time.", preview: preview, usage: nil)
        XCTAssertEqual(LocalHelperFill.notes(for: kept), [
            "The local model did not answer in time.",
            "Truncated: only the first 1 of 4 files were sent."
        ])
        let long = PullRequestDraftText(commitMessage: String(repeating: "a", count: 73) + "\n", title: "t", body: "b")
        let drafted = LocalHelperOutcome(draft: long, fallbackReason: nil, preview: nil, usage: nil)
        XCTAssertEqual(LocalHelperFill.notes(for: drafted), ["The commit subject is longer than 72 characters."])
        let fine = LocalHelperOutcome(draft: "An answer.", fallbackReason: nil, preview: nil, usage: nil)
        XCTAssertEqual(LocalHelperFill.notes(for: fine), [])
    }

    func testAnExplanationBelongsToTheFailureItExplains() {
        func result(exit: Int32, output: String) -> VerificationResult {
            VerificationResult(command: nil, exitCode: exit, durationSeconds: 2, standardOutput: output, standardError: "", wasCancelled: false, timedOut: false)
        }
        XCTAssertEqual(LocalHelperFill.failureKey(result(exit: 1, output: "x")), LocalHelperFill.failureKey(result(exit: 1, output: "x")))
        XCTAssertNotEqual(LocalHelperFill.failureKey(result(exit: 1, output: "x")), LocalHelperFill.failureKey(result(exit: 2, output: "x")))
        XCTAssertNotEqual(LocalHelperFill.failureKey(result(exit: 1, output: "x")), LocalHelperFill.failureKey(result(exit: 1, output: "xy")))
    }

    func testEveryNoteTheHelperShowsIsTranslated() {
        for note in [
            "The local model helper is off. Turn it on in Local model settings.",
            "Truncated: only the first 2 of 5 files were sent.",
            "The local model could not draft this: The run timed out and the child process was stopped.",
            "The commit subject is longer than 72 characters."
        ] {
            XCTAssertNotEqual(AppLocalization.display(note, language: .traditionalChinese), note, note)
        }
    }
}
