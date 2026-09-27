import XCTest
@testable import NexusSelfMonitor

final class UploadQueueTests: XCTestCase {
    @MainActor
    private func enqueue(_ queue: UploadQueue, seq: Int) {
        queue.enqueue(kind: "audio", ext: "m4a", contentType: "audio/mp4",
                      sessionId: "session-a", seq: seq, startedAt: 1,
                      durationMs: 5000, data: Data(repeating: 1, count: 128))
    }

    @MainActor
    private func waitUntilIdle(_ queue: UploadQueue) async throws {
        let deadline = Date().addingTimeInterval(2)
        while queue.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(queue.isProcessing, "Retry handler did not finish")
    }

    @MainActor
    func testEnqueueDuringSuspendedUploadSurvivesCompletionAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = UploadQueue(directory: directory)
        defer { queue.stopProcessing(); try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "Upload suspended")
        var resume: CheckedContinuation<Bool, Never>?
        queue.setUploadHandler { _ in
            await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }
        enqueue(queue, seq: 1)
        queue.retryNow()
        await fulfillment(of: [entered], timeout: 2)
        enqueue(queue, seq: 2)
        resume?.resume(returning: true)
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.totalDiskBytes, 128)
        let restored = UploadQueue(directory: directory)
        XCTAssertEqual(restored.pendingCount, 1, "New item must remain in the persisted index")
        let retried = expectation(description: "New item uploaded")
        restored.setUploadHandler { item in
            XCTAssertEqual(item.seq, 2)
            retried.fulfill()
            return true
        }
        restored.retryNow()
        await fulfillment(of: [retried], timeout: 2)
        try await waitUntilIdle(restored)
        restored.stopProcessing()
        XCTAssertEqual(restored.pendingCount, 0)
    }

    @MainActor
    func testStopAndRestartCannotOverlapOrAcknowledgeOldAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = UploadQueue(directory: directory)
        defer { queue.stopProcessing(); try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "First attempt")
        var resume: CheckedContinuation<Bool, Never>?
        var attempts = 0
        queue.setUploadHandler { _ in
            attempts += 1
            return await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }
        enqueue(queue, seq: 1)
        enqueue(queue, seq: 2)
        queue.retryNow()
        await fulfillment(of: [entered], timeout: 2)
        queue.stopProcessing()
        XCTAssertTrue(queue.isProcessing, "Suspended work must retain its processing slot")
        queue.retryNow()
        await Task.yield()
        XCTAssertEqual(attempts, 1)
        resume?.resume(returning: true)
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.pendingCount, 2, "Canceled generation must not delete or retry items")
    }

    @MainActor
    func testFailureStopsBatchAndPreservesNewItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = UploadQueue(directory: directory)
        defer { queue.stopProcessing(); try? FileManager.default.removeItem(at: directory) }
        let attempted = expectation(description: "One attempt")
        var attempts = 0
        queue.setUploadHandler { _ in
            attempts += 1
            self.enqueue(queue, seq: 3)
            attempted.fulfill()
            return false
        }
        enqueue(queue, seq: 1)
        enqueue(queue, seq: 2)
        queue.retryNow()
        await fulfillment(of: [attempted], timeout: 2)
        try await waitUntilIdle(queue)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(UploadQueue(directory: directory).pendingCount, 3)
    }

    @MainActor
    func testEvictionDoesNotDeleteFileBeingUploaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = UploadQueue(directory: directory)
        defer { queue.stopProcessing(); try? FileManager.default.removeItem(at: directory) }
        let entered = expectation(description: "Upload suspended")
        var resume: CheckedContinuation<Bool, Never>?
        var uploadedPath: String?
        queue.setUploadHandler { item in
            uploadedPath = item.filePath
            return await withCheckedContinuation {
                resume = $0
                entered.fulfill()
            }
        }
        enqueue(queue, seq: 0)
        queue.retryNow()
        await fulfillment(of: [entered], timeout: 2)
        for seq in 1...151 { enqueue(queue, seq: seq) }
        XCTAssertEqual(queue.pendingCount, 150)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(uploadedPath)))
        resume?.resume(returning: true)
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.pendingCount, 149)
    }
}
