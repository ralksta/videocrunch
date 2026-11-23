import Darwin
import Foundation
import IOKit

/// Raw cumulative CPU tick counters from Mach `HOST_CPU_LOAD_INFO`.
struct CPUTicks: Equatable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    static func readHostCPUTicks() -> CPUTicks? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info_data_t()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    static func usagePercent(previous: CPUTicks, current: CPUTicks) -> Int? {
        let userDelta = UInt64(current.user &- previous.user)
        let systemDelta = UInt64(current.system &- previous.system)
        let idleDelta = UInt64(current.idle &- previous.idle)
        let niceDelta = UInt64(current.nice &- previous.nice)

        let activeDelta = userDelta + systemDelta + niceDelta
        let totalDelta = activeDelta + idleDelta
        guard totalDelta > 0 else { return nil }

        let raw = Int((activeDelta * 100) / totalDelta)
        return max(0, min(100, raw))
    }
}

/// Public, App Sandbox–safe hardware utilization readers (`Darwin` Mach + `IOKit`).
enum SystemTelemetry {
    static func readGPUUtilizationPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
            let dict = properties?.takeRetainedValue() as? [String: Any],
            let stats = dict["PerformanceStatistics"] as? [String: Any] else {
                continue
            }

            if let num = (stats["Device Utilization %"] as? NSNumber)
                ?? (stats["Renderer Utilization %"] as? NSNumber) {
                return max(0, min(100, num.intValue))
            }
        }
        return nil
    }
}

/// Polls aggregate macOS CPU and GPU utilization once per second while encoding is active.
@MainActor
final class SystemLoadMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Int?
    @Published private(set) var gpuPercent: Int?

    private var timer: Timer?
    private var previousTicks: CPUTicks?

    func start() {
        guard timer == nil else { return }
        previousTicks = CPUTicks.readHostCPUTicks()
        gpuPercent = SystemTelemetry.readGPUUtilizationPercent()

        let created = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sample()
            }
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousTicks = nil
        cpuPercent = nil
        gpuPercent = nil
    }

    private func sample() {
        let currentTicks = CPUTicks.readHostCPUTicks()
        if let prev = previousTicks, let curr = currentTicks {
            cpuPercent = CPUTicks.usagePercent(previous: prev, current: curr)
        }
        previousTicks = currentTicks
        gpuPercent = SystemTelemetry.readGPUUtilizationPercent()
    }
}
