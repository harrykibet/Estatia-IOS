import XCTest
@testable import CorePlayerEngine

private struct TestLatencyMeasurer: LatencyMeasurer {
    func measure(url: URL) async -> TimeInterval? { nil }
}

final class CdnHealthMonitorTests: XCTestCase {
    func testThreeFailuresOpenCircuitForSixtySeconds() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let cdn = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: TestLatencyMeasurer(), clock: { now })

        await monitor.recordFailure(for: cdn)
        await monitor.recordFailure(for: cdn)
        await monitor.recordFailure(for: cdn)

        let health = await monitor.health(for: cdn)
        XCTAssertEqual(health?.consecutiveFailures, 3)
        XCTAssertTrue(health?.isCircuitOpen(at: now) == true)
        XCTAssertFalse(health?.isCircuitOpen(at: now.addingTimeInterval(60)) == true)
    }

    func testSuccessClearsFailureCountAndCircuit() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let cdn = Cdn(id: "primary", baseURL: URL(string: "https://primarycdn.estatia.com")!)
        let monitor = CdnHealthMonitor(measurer: TestLatencyMeasurer(), clock: { now })
        await monitor.recordFailure(for: cdn)
        await monitor.recordFailure(for: cdn)
        await monitor.recordFailure(for: cdn)
        await monitor.recordSuccess(for: cdn, latency: 0.025)

        let health = await monitor.health(for: cdn)
        XCTAssertEqual(health?.consecutiveFailures, 0)
        XCTAssertEqual(health?.latency, 0.025)
        XCTAssertFalse(health?.isCircuitOpen(at: now) == true)
    }
}
