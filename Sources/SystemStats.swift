import Foundation
import Darwin
import IOKit.ps
import Combine

/// Tidier reads CPU / RAM / battery straight from the system, so the dashboard rings
/// are reliable and live — independent of whether iStat's menu bar items can be
/// captured. Values are 0…100 percent; `battery` is nil on desktops.
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var ram: Double = 0
    @Published private(set) var battery: Double? = nil

    private var timer: Timer?
    private var prevCPU: host_cpu_load_info?

    /// Begin sampling (call while the panel is open); `refresh()` once immediately.
    func start(interval: TimeInterval = 2) {
        refresh()   // seeds the CPU baseline (CPU needs two samples for a delta)
        // A quick follow-up so CPU isn't stuck at 0 for the first interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        if let c = readCPU() { cpu = c }
        ram = readRAM()
        battery = readBattery()
    }

    // MARK: - Readers

    private func readCPU() -> Double? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { prevCPU = info }
        guard let p = prevCPU else { return nil }   // first sample seeds the baseline
        let user = Double(info.cpu_ticks.0 - p.cpu_ticks.0)
        let sys  = Double(info.cpu_ticks.1 - p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - p.cpu_ticks.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total * 100 : 0
    }

    private func readRAM() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? used / total * 100 : 0
    }

    private func readBattery() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Double(current) / Double(max) * 100
        }
        return nil
    }
}
