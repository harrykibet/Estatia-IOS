import Foundation
import XCTest
@testable import CorePlayerEngine

private actor ScriptedMediaDataFetcher: MediaDataFetching {
    enum Step: Sendable { case failure, response(Int) }
    private var steps: [Step]
    private var sources: [MediaSource] = []

    init(steps: [Step]) { self.steps = steps }

    func fetch(source: MediaSource, offset: Int64, length: Int) async throws -> MediaDataFetchResponse {
        sources.append(source)
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case .failure:
            throw URLError(.timedOut)
        case .response(let status):
            return MediaDataFetchResponse(
                statusCode: status,
                data: Data([1, 2, 3]),
                contentType: "video/mp4",
                totalLength: 100
            )
        }
    }

    func requestedSources() -> [MediaSource] { sources }
}

private struct NoFailoverProbeMeasurer: LatencyMeasurer {
    func measure(url: URL) async -> TimeInterval? { nil }
}

final class CdnFailoverTests: XCTestCase {
    private func makeSelector() async -> CdnSelector {
        let now = Date(timeIntervalSince1970: 6_000)
        let primary = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let backup = Cdn(id: "backup", baseURL: URL(string: "https://backupcdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: NoFailoverProbeMeasurer(), clock: { now })
        await monitor.recordSuccess(for: primary, latency: 0.020)
        await monitor.recordSuccess(for: backup, latency: 0.040)
        return CdnSelector(cdns: [primary, backup], healthMonitor: monitor)
    }

    func testRetriesTimedOutRequestOnDifferentCDNAndPreservesURLAndHeaders() async throws {
        let selector = await makeSelector()
        let base = ScriptedMediaDataFetcher(steps: [.failure, .response(206)])
        let fetcher = CdnFailoverMediaDataFetcher(baseFetcher: base, selector: selector)
        let source = MediaSource(
            url: URL(string: "https://media.estatia.com/listing/clip.mp4?token=abc#part")!,
            type: .progressive,
            headers: ["Authorization": "Bearer test"]
        )

        let result = try await fetcher.fetch(source: source, offset: 128, length: 512)
        let requests = await base.requestedSources()

        XCTAssertEqual(result.statusCode, 206)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.host, "primarycdn.estatia.com")
        XCTAssertEqual(requests[1].url.host, "backupcdn.estatia.com")
        XCTAssertEqual(requests[1].url.path, "/listing/clip.mp4")
        XCTAssertEqual(requests[1].url.query, "token=abc")
        XCTAssertEqual(requests[1].url.fragment, "part")
        XCTAssertEqual(requests[1].headers, source.headers)
        XCTAssertEqual(requests[1].type, source.type)
    }

    func testRetriesServerFailureStatusOnce() async throws {
        let selector = await makeSelector()
        let base = ScriptedMediaDataFetcher(steps: [.response(503), .response(206)])
        let fetcher = CdnFailoverMediaDataFetcher(baseFetcher: base, selector: selector)
        let source = MediaSource(url: URL(string: "https://media.estatia.com/clip.mp4?token=abc")!)
        let result = try await fetcher.fetch(source: source, offset: 0, length: 256)
        let requests = await base.requestedSources()

        XCTAssertEqual(result.statusCode, 206)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.host, "primarycdn.estatia.com")
        XCTAssertEqual(requests[1].url.host, "backupcdn.estatia.com")
    }

    func testThirdPartyMediaIsNotRewritten() async throws {
        let selector = await makeSelector()
        let base = ScriptedMediaDataFetcher(steps: [.response(206)])
        let fetcher = CdnFailoverMediaDataFetcher(baseFetcher: base, selector: selector)
        let source = MediaSource(url: URL(string: "https://cdn.example.net/clip.mp4")!)
        _ = try await fetcher.fetch(source: source, offset: 0, length: 256)
        let requests = await base.requestedSources()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url.host, "cdn.example.net")
    }

    func testSecondEndpointFailureIsTerminalWithoutLooping() async {
        let selector = await makeSelector()
        let base = ScriptedMediaDataFetcher(steps: [.failure, .failure])
        let fetcher = CdnFailoverMediaDataFetcher(baseFetcher: base, selector: selector)
        let source = MediaSource(url: URL(string: "https://media.estatia.com/clip.mp4")!)

        do {
            _ = try await fetcher.fetch(source: source, offset: 0, length: 256)
            XCTFail("Expected the second endpoint failure to propagate")
        } catch {
            XCTAssertTrue(error is URLError)
        }
        let requests = await base.requestedSources()
        XCTAssertEqual(requests.count, 2)
    }
}
