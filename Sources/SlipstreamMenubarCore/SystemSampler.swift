import Darwin
import Foundation
import IOKit

/// Host statistics for the panel's System section, from public APIs only:
/// per-CPU tick counters, the GPU accelerator's PerformanceStatistics in the
/// IOKit registry, vm_statistics64 and vm.swapusage.
public struct SystemSnapshot: Equatable, Sendable {
    public var time: Date
    /// 0...1, averaged over all cores since the previous sample.
    public var cpuUsage: Double?
    /// 0...1, the GPU's own utilization figure.
    public var gpuUsage: Double?
    public var memoryTotalBytes: Double
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var memoryUsedBytes: Double
    public var memoryWiredBytes: Double
    public var memoryCompressedBytes: Double
    public var swapUsedBytes: Double
    /// "normal", "warning" or "critical".
    public var memoryPressure: String
}

public final class SystemSampler {
    private var previousTicks: [UInt64]?

    public init() {}

    public func sample(at time: Date = Date()) -> SystemSnapshot {
        let memory = Self.readMemory()
        return SystemSnapshot(
            time: time,
            cpuUsage: cpuUsage(),
            gpuUsage: Self.readGPUUsage(),
            memoryTotalBytes: Double(ProcessInfo.processInfo.physicalMemory),
            memoryUsedBytes: memory.used,
            memoryWiredBytes: memory.wired,
            memoryCompressedBytes: memory.compressed,
            swapUsedBytes: Self.readSwapUsed(),
            memoryPressure: Self.readMemoryPressure()
        )
    }

    // MARK: CPU

    /// Busy share of all ticks since the previous call; nil on the first call.
    private func cpuUsage() -> Double? {
        guard let ticks = Self.readCPUTicks() else { return nil }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }
        // ticks holds [user, system, idle, nice] per CPU, flattened.
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in stride(from: 0, to: ticks.count, by: 4) {
            let delta = (0..<4).map { ticks[cpu + $0] &- previous[cpu + $0] }
            busy += delta[0] + delta[1] + delta[3]
            total += delta.reduce(0, +)
        }
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    private static func readCPUTicks() -> [UInt64]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [UInt64] = []
        ticks.reserveCapacity(Int(cpuCount) * 4)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            for state in [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE] {
                ticks.append(UInt64(UInt32(bitPattern: info[base + Int(state)])))
            }
        }
        return ticks
    }

    // MARK: GPU

    private static func readGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var usage: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard usage == nil,
                  let property = IORegistryEntryCreateCFProperty(
                    service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let percent = statistics["Device Utilization %"] as? NSNumber else { continue }
            usage = percent.doubleValue / 100
        }
        return usage
    }

    // MARK: Memory

    private static func readMemory() -> (used: Double, wired: Double, compressed: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        return (max(0, app * page) + wired + compressed, wired, compressed)
    }

    private static func readSwapUsed() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used)
    }

    private static func readMemoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return "normal"
        }
        switch level {
        case 4: return "critical"
        case 2: return "warning"
        default: return "normal"
        }
    }
}
