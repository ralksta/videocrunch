import XCTest
@testable import VideoCrunch

final class SystemTelemetryTests: XCTestCase {
    func testCPUTicksUsagePercentEdgeCases() {
        let base = CPUTicks(user: 100, system: 50, idle: 200, nice: 10)

        // Zero elapsed ticks -> nil
        XCTAssertNil(CPUTicks.usagePercent(previous: base, current: base))

        // 0% CPU (all delta in idle)
        let allIdle = CPUTicks(user: 100, system: 50, idle: 400, nice: 10)
        XCTAssertEqual(CPUTicks.usagePercent(previous: base, current: allIdle), 0)

        // 50% CPU (50 active, 50 idle)
        let halfLoad = CPUTicks(user: 130, system: 65, idle: 250, nice: 15)
        XCTAssertEqual(CPUTicks.usagePercent(previous: base, current: halfLoad), 50)

        // 100% CPU (all delta in active)
        let fullLoad = CPUTicks(user: 200, system: 100, idle: 200, nice: 20)
        XCTAssertEqual(CPUTicks.usagePercent(previous: base, current: fullLoad), 100)

        // UInt32 counter wrap-around
        let beforeWrap = CPUTicks(user: UInt32.max - 10, system: 100, idle: UInt32.max - 20, nice: 0)
        let afterWrap = CPUTicks(user: 19, system: 130, idle: 19, nice: 0)
        // active delta = 30 + 30 = 60; idle delta = 40 -> 60%
        XCTAssertEqual(CPUTicks.usagePercent(previous: beforeWrap, current: afterWrap), 60)
    }

    func testReadHostCPUTicksReturnsValidSampleOnMacOS() {
        let ticks = CPUTicks.readHostCPUTicks()
        XCTAssertNotNil(ticks)
        if let ticks {
            let total = UInt64(ticks.user) + UInt64(ticks.system) + UInt64(ticks.idle) + UInt64(ticks.nice)
            XCTAssertGreaterThan(total, 0)
        }
    }
}
