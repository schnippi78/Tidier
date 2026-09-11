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
    @Published private(set) var disk: Double = 0          // % used, boot volume
    @Published private(set) var diskUsedGB: Double = 0
    @Published private(set) var diskTotalGB: Double = 0
    @Published private(set) var netDown: Double = 0       // MB/s
    @Published private(set) var netUp: Double = 0         // MB/s

    private var timer: Timer?
    private var prevCPU: host_cpu_load_info?
    private var prevNet: (rx: UInt64, tx: UInt64)?
    private var prevNetTime: CFAbsoluteTime = 0

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
        readDisk()
        readNetwork()
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

    private func readDisk() {
        var st = statfs()
        guard statfs("/", &st) == 0 else { return }
        let total = Double(st.f_blocks) * Double(st.f_bsize)
        let free  = Double(st.f_bavail) * Double(st.f_bsize)
        guard total > 0 else { return }
        disk = (total - free) / total * 100
        diskTotalGB = total / 1e9
        diskUsedGB = (total - free) / 1e9
    }

    /// Throughput = byte delta over the sample interval, summed over en* interfaces.
    private func readNetwork() {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let name = String(cString: cur.pointee.ifa_name)
                if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   name.hasPrefix("en"), let raw = cur.pointee.ifa_data {
                    let d = raw.assumingMemoryBound(to: if_data.self)
                    rx += UInt64(d.pointee.ifi_ibytes); tx += UInt64(d.pointee.ifi_obytes)
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }
        let now = CFAbsoluteTimeGetCurrent()
        defer { prevNet = (rx, tx); prevNetTime = now }
        guard let prev = prevNet, now > prevNetTime else { return }
        let dt = now - prevNetTime
        // UInt64 subtraction guards against counter resets.
        let dRx = rx >= prev.rx ? Double(rx - prev.rx) : 0
        let dTx = tx >= prev.tx ? Double(tx - prev.tx) : 0
        netDown = dRx / dt / 1e6
        netUp   = dTx / dt / 1e6
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
