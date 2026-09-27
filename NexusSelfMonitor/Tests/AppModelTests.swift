import XCTest
@testable import NexusSelfMonitor

final class AppModelTests: XCTestCase {
    @MainActor
    func testDuplicateStartAndStopWhilePermissionIsPending() async {
        let entered = expectation(description: "Permission pending")
        var resume: CheckedContinuation<Bool, Never>?
        var permissionRequests = 0
        let model = AppModel(settings: Settings(), microphonePermission: {
            permissionRequests += 1
            return await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }, automaticStartup: false)
        model.hasConsented = true
        let first = Task { await model.start() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isStarting)
        await model.start()
        XCTAssertEqual(permissionRequests, 1)
        model.stop()
        resume?.resume(returning: true)
        await first.value
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.isMonitoring)
        XCTAssertEqual(model.status, "Idle")
        XCTAssertNil(model.lastErrorText, "Canceled startup must never try to register a session")
    }

    @MainActor
    func testConsentRemovedWhilePermissionIsPendingPreventsStartup() async {
        let entered = expectation(description: "Permission pending")
        var resume: CheckedContinuation<Bool, Never>?
        let model = AppModel(settings: Settings(), microphonePermission: {
            await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }, automaticStartup: false)
        model.hasConsented = true
        let task = Task { await model.start() }
        await fulfillment(of: [entered], timeout: 2)
        model.hasConsented = false
        resume?.resume(returning: true)
        await task.value
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.isMonitoring)
        XCTAssertNil(model.lastErrorText)
    }
}
