import XCTest
@testable import CorePlayerEngine

final class PlayerPoolSizingPolicyTests: XCTestCase {
    private let policy = PlayerPoolSizingPolicy()

    func testCapacityScalesWithPhysicalMemoryAndConfiguredMaximum() {
        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: PlayerPoolEnvironment(physicalMemoryMB: 2_048),
                configuredMaximum: 4
            ),
            1
        )
        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: PlayerPoolEnvironment(physicalMemoryMB: 4_096),
                configuredMaximum: 4
            ),
            2
        )
        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: PlayerPoolEnvironment(physicalMemoryMB: 5_500),
                configuredMaximum: 4
            ),
            3
        )
        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: PlayerPoolEnvironment(physicalMemoryMB: 8_192),
                configuredMaximum: 3
            ),
            3
        )
    }

    func testFairThermalStateReducesCapacityByOne() {
        let environment = PlayerPoolEnvironment(
            physicalMemoryMB: 8_192,
            thermalState: .fair
        )

        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: environment,
                configuredMaximum: 4
            ),
            3
        )
    }

    func testSeriousAndCriticalThermalStatesForceSinglePlayer() {
        for thermalState in [
            PlayerPoolEnvironment.ThermalState.serious,
            .critical
        ] {
            XCTAssertEqual(
                policy.calculateMaxPlayers(
                    environment: PlayerPoolEnvironment(
                        physicalMemoryMB: 8_192,
                        thermalState: thermalState
                    ),
                    configuredMaximum: 4
                ),
                1
            )
        }
    }

    func testBackgroundLowPowerAndMemoryWarningForceSinglePlayer() {
        let environments = [
            PlayerPoolEnvironment(
                physicalMemoryMB: 8_192,
                isAppVisible: false
            ),
            PlayerPoolEnvironment(
                physicalMemoryMB: 8_192,
                isLowPowerModeEnabled: true
            ),
            PlayerPoolEnvironment(
                physicalMemoryMB: 8_192,
                memoryPressure: .warning
            )
        ]

        for environment in environments {
            XCTAssertEqual(
                policy.calculateMaxPlayers(
                    environment: environment,
                    configuredMaximum: 4
                ),
                1
            )
        }
    }

    func testConfiguredMaximumIsAlwaysAHardUpperBound() {
        let environment = PlayerPoolEnvironment(physicalMemoryMB: 16_384)

        XCTAssertEqual(
            policy.calculateMaxPlayers(
                environment: environment,
                configuredMaximum: 2
            ),
            2
        )
    }
}
