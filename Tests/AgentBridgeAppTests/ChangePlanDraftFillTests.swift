import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// A drafted plan fills the plan form, and text the user wrote there is only
/// replaced after they agree.
final class ChangePlanDraftFillTests: XCTestCase {
    private typealias Fields = ChangePlanDraftFill.Fields

    func testBlankFieldsAreFilledWithoutAsking() {
        XCTAssertFalse(ChangePlanDraftFill.replacesUserText(title: "", summary: "", stepsText: ""))
        XCTAssertFalse(ChangePlanDraftFill.replacesUserText(title: "  ", summary: "\n", stepsText: " \n\t"))
    }

    func testAnyFieldWithTextNeedsAnAnswerFirst() {
        XCTAssertTrue(ChangePlanDraftFill.replacesUserText(title: "Mine", summary: "", stepsText: ""))
        XCTAssertTrue(ChangePlanDraftFill.replacesUserText(title: "", summary: "Mine", stepsText: ""))
        XCTAssertTrue(ChangePlanDraftFill.replacesUserText(title: "", summary: "", stepsText: "\nOne step\n"))
    }

    func testAFinishedDraftAsksAgainOnlyWhenTheFormChangedToNewText() {
        let atStart = Fields(title: "Agreed", summary: "To replace", stepsText: "Old step")
        XCTAssertTrue(ChangePlanDraftFill.canFillWithoutAsking(current: atStart, atStart: atStart))
        XCTAssertTrue(ChangePlanDraftFill.canFillWithoutAsking(current: Fields(title: "", summary: " ", stepsText: ""), atStart: atStart))
        XCTAssertFalse(ChangePlanDraftFill.canFillWithoutAsking(
            current: Fields(title: "Reloaded saved plan", summary: "To replace", stepsText: "Old step"),
            atStart: atStart
        ))
        let empty = Fields(title: "", summary: "", stepsText: "")
        XCTAssertFalse(ChangePlanDraftFill.canFillWithoutAsking(current: Fields(title: "Typed later", summary: "", stepsText: ""), atStart: empty))
    }

    func testTheDraftFillsOneStepPerLineAndMatchesTheSavedPlanAfterSaving() {
        let draft = DraftedChangePlan(title: "Title", summary: "Summary", steps: ["First.", "Second."])
        let fields = ChangePlanDraftFill.fields(for: draft)
        XCTAssertEqual(fields, Fields(title: "Title", summary: "Summary", stepsText: "First.\nSecond."))
        let plan = ChangePlan(sessionID: UUID(), title: draft.title, summary: draft.summary, steps: draft.steps)
        XCTAssertTrue(ChangePlanDraft(title: fields.title, summary: fields.summary, stepsText: fields.stepsText).matches(plan))
    }
}
