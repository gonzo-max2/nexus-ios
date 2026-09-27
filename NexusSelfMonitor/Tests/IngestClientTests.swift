import XCTest
@testable import NexusSelfMonitor

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int((request.url?.host ?? "").replacingOccurrences(of: "status-", with: "")
            .replacingOccurrences(of: ".test", with: "")) ?? 200
        let body = status == 200 ? Data("{\"sessionId\":\"test-session\",\"ok\":true}".utf8) : Data("rejected".utf8)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class IngestClientTests: XCTestCase {
    private func client(status: Int) -> IngestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var settings = Settings()
        settings.serverURL = "https://status-\(status).test"
        return IngestClient(settings: settings, session: URLSession(configuration: config))
    }

    func testSessionResponseIsDecoded() async throws {
        let sid = try await client(status: 200).startSession()
        XCTAssertEqual(sid, "test-session")
    }

    func testHTTPFailuresAreClassified() async {
        for status in [401, 403, 429, 500] {
            do {
                _ = try await client(status: status).startSession()
                XCTFail("Expected failure for HTTP \(status)")
            } catch let error as IngestClient.ClientError {
                XCTAssertEqual(error.isTransient, status == 429 || status == 500)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPersistedFileUploadPropagatesHTTPFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await client(status: 401).uploadMedia(sessionId: "s", kind: "photo", ext: "jpg",
                contentType: "image/jpeg", seq: 1, fileURL: file, startedAt: 1, durationMs: nil)
            XCTFail("Unauthorized file upload must fail")
        } catch IngestClient.ClientError.unauthorized {
            // Expected: a rejected retry must remain in the queue.
        }
    }
}
