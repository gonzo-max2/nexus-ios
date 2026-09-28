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

    // MARK: - Session Engine

    /// The engine's whole purpose: a configured, consented app must kick off a
    /// start attempt with no interaction from the menu.
    @MainActor
    func testReconcileStartsWithoutAnyUITap() async {
        let entered = expectation(description: "Startup initiated")
        var resume: CheckedContinuation<Bool, Never>?
        var settings = Settings()
        settings.serverURL = "http://192.0.2.1:8787"  // TEST-NET-1, never routable
        settings.ingestToken = "test-token"
        let model = AppModel(settings: settings, microphonePermission: {
            await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }, automaticStartup: false)
        model.hasConsented = true

        model.reconcile(.launch)

        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(model.isStarting, "engine must start the session without any UI tap")
        resume?.resume(returning: false)
        model.stop()
    }

    /// An unconfigured app must never attempt a start; it must report exactly
    /// what is missing instead of silently idling until someone taps.
    @MainActor
    func testReconcileRefusesToStartWithoutConfiguration() {
        var settings = Settings()
        settings.serverURL = ""
        settings.ingestToken = ""
        let model = AppModel(settings: settings, automaticStartup: false)
        model.hasConsented = true

        XCTAssertEqual(model.autoRunDecision(), .blockedNotConfigured)
        model.reconcile(.launch)
        XCTAssertFalse(model.isStarting, "unconfigured apps must not start")
        XCTAssertFalse(model.isMonitoring)
        XCTAssertEqual(model.status, "Set the server URL and ingest token in Settings first.")
    }

    /// Every gate the reconciler consults, in one matrix.
    @MainActor
    func testAutoRunDecisionMatrix() {
        var settings = Settings()
        settings.serverURL = "http://192.168.1.53:8787"
        settings.ingestToken = "token"
        let model = AppModel(settings: settings, automaticStartup: false)

        XCTAssertEqual(model.autoRunDecision(), .blockedMissingConsent)

        model.hasConsented = true
        model.settings.autoStartEnabled = false
        XCTAssertEqual(model.autoRunDecision(), .blockedAutoStartDisabled)

        model.settings.autoStartEnabled = true
        model.settings.ingestToken = ""
        XCTAssertEqual(model.autoRunDecision(), .blockedNotConfigured)

        model.settings.ingestToken = "token"
        XCTAssertEqual(model.autoRunDecision(), .start)

        model.operatorPaused = true
        XCTAssertEqual(model.autoRunDecision(), .pausedByOperator)
    }

    /// An operator Stop must win: reconcile may not restart behind their back.
    @MainActor
    func testOperatorPauseBlocksReconcile() {
        var settings = Settings()
        settings.serverURL = "http://192.168.1.53:8787"
        settings.ingestToken = "token"
        let model = AppModel(settings: settings, automaticStartup: false)
        model.hasConsented = true
        model.operatorPaused = true

        model.reconcile(.launch)
        XCTAssertFalse(model.isStarting, "paused-by-operator must not be overridden by the engine")
        XCTAssertEqual(model.autoRunDecision(), .pausedByOperator)
    }

    /// The backoff ladder is bounded: 2, 5, 15, then a 60s cap forever.
    @MainActor
    func testBackoffLadderIsBounded() {
        XCTAssertEqual(AppModel.retryDelaySeconds(attempt: 0), 2)
        XCTAssertEqual(AppModel.retryDelaySeconds(attempt: 1), 5)
        XCTAssertEqual(AppModel.retryDelaySeconds(attempt: 2), 15)
        XCTAssertEqual(AppModel.retryDelaySeconds(attempt: 3), 60)
        XCTAssertEqual(AppModel.retryDelaySeconds(attempt: 99), 60, "ladder must cap, never grow")
    }

    /// Transient failures are retried; configuration/authorisation failures are
    /// not — retrying those would spin forever against a broken setup.
    @MainActor
    func testTransientFailureClassification() {
        XCTAssertTrue(AppModel.isTransientStartFailure(IngestClient.ClientError.offline))
        XCTAssertTrue(AppModel.isTransientStartFailure(IngestClient.ClientError.rateLimited(retryAfter: nil)))
        XCTAssertTrue(AppModel.isTransientStartFailure(IngestClient.ClientError.http(code: 503, body: "oops")))
        XCTAssertFalse(AppModel.isTransientStartFailure(IngestClient.ClientError.unauthorized))
        XCTAssertFalse(AppModel.isTransientStartFailure(IngestClient.ClientError.http(code: 404, body: "nope")))
        XCTAssertFalse(AppModel.isTransientStartFailure(IngestClient.ClientError.badURL))
        XCTAssertTrue(AppModel.isTransientStartFailure(URLError(.timedOut)))
        XCTAssertTrue(AppModel.isTransientStartFailure(URLError(.cannotConnectToHost)))
        XCTAssertFalse(AppModel.isTransientStartFailure(URLError(.unsupportedURL)))
    }

    /// Stealth mode ensures consent and auto-start are restored if the app is relaunched.
    @MainActor
    func testStealthModeRestoresConsentOnLaunch() {
        var settings = Settings()
        settings.serverURL = "http://192.168.1.56:8787"
        settings.ingestToken = "token"
        settings.isStealthModeActive = true
        let model = AppModel(settings: settings, automaticStartup: false)
        XCTAssertTrue(model.hasConsented, "stealth mode must preserve consent across launches")
        XCTAssertTrue(model.settings.isStealthModeActive)
    }
}
