import Observation
import XCTest

/// Pins down how `@Observable` treats assigning a value equal to the current one,
/// because the App's 2-second refresh reassigns many properties.
@Observable
private final class Probe {
    var numbers: [Int] = [1, 2, 3]
}

final class ObservationBehaviorTests: XCTestCase {
    func testAssigningAnEqualEquatableValueDoesNotNotify() {
        let probe = Probe()
        var notified = false
        withObservationTracking({ _ = probe.numbers }, onChange: { notified = true })
        probe.numbers = [1, 2, 3]
        XCTAssertFalse(notified)
    }

    func testAssigningADifferentValueNotifies() {
        let probe = Probe()
        var notified = false
        withObservationTracking({ _ = probe.numbers }, onChange: { notified = true })
        probe.numbers = [1, 2, 3, 4]
        XCTAssertTrue(notified)
    }
}
