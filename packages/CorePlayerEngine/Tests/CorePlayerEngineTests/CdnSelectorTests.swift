import XCTest
@testable import CorePlayerEngine

private struct NoProbeLatencyMeasurer: LatencyMeasurer {
    func measure(url: URL) async -> TimeInterval? { nil }
}

final class CdnSelectorTests: XCTestCase {
    func testSelectsLowestLatencyHealthyEndpoint() async {
        let now = Date(timeIntervalSince1970: 3_000)
        let primary = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let backup = Cdn(id: "backup", baseURL: URL(string: "https://backupcdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: NoProbeLatencyMeasurer(), clock: { now })
        await monitor.recordSuccess(for: primary, latency: 0.090)
        await monitor.recordSuccess(for: backup, latency: 0.035)

        let selector = CdnSelector(cdns: [primary, backup], healthMonitor: monitor)
        let selected = await selector.selectBestCdn(forPath: "/movie/segment.ts")
        XCTAssertEqual(selected?.id, "backup")
    }

    func testSkipsCircuitOpenEndpoint() async {
        let now = Date(timeIntervalSince1970: 4_000)
        let primary = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let backup = Cdn(id: "backup", baseURL: URL(string: "https://backupcdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: NoProbeLatencyMeasurer(), clock: { now })
        await monitor.recordSuccess(for: primary, latency: 0.010)
        await monitor.recordSuccess(for: backup, latency: 0.050)
        await monitor.recordFailure(for: primary)
        await monitor.recordFailure(for: primary)
        await monitor.recordFailure(for: primary)

        let selector = CdnSelector(cdns: [primary, backup], healthMonitor: monitor)
        let selected = await selector.selectBestCdn(forPath: "/movie/segment.ts")
        XCTAssertEqual(selected?.id, "backup")
    }

    func testExcludesFailedEndpointFromRetrySelection() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let primary = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let backup = Cdn(id: "backup", baseURL: URL(string: "https://backupcdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: NoProbeLatencyMeasurer(), clock: { now })
        await monitor.recordSuccess(for: primary, latency: 0.010)
        await monitor.recordSuccess(for: backup, latency: 0.050)

        let selector = CdnSelector(cdns: [primary, backup], healthMonitor: monitor)
        let selected = await selector.selectBestCdn(
            forPath: "/movie/segment.ts",
            excluding: ["primary"]
        )
        XCTAssertEqual(selected?.id, "backup")
    }
}
