import Darwin
import Foundation

/// État de l'appareil lui-même (le Mac, ou l'iPhone) : processeur, mémoire, stockage, réseau, chaleur.
/// Fonctionne sans PC connecté.
struct LocalStats {
    var cpu: Double
    var ramUsedGB: Double
    var ramTotalGB: Double
    var diskUsedGB: Double
    var diskTotalGB: Double
    var upKBs: Double
    var downKBs: Double
    var sentGB: Double
    var recvGB: Double
    var uptime: TimeInterval
    var thermal: ProcessInfo.ThermalState
    var history: [Double]

    var ramPercent: Double { ramTotalGB > 0 ? ramUsedGB / ramTotalGB * 100 : 0 }
    var diskPercent: Double { diskTotalGB > 0 ? diskUsedGB / diskTotalGB * 100 : 0 }

    var thermalLabel: String {
        switch thermal {
        case .nominal: return "Normale"
        case .fair: return "Tiède"
        case .serious: return "Chaude"
        case .critical: return "Critique"
        @unknown default: return "Inconnue"
        }
    }

    /// Note de santé sur 100, comme sur le PC.
    var health: (score: Int, grade: String, advice: String) {
        var score = 100.0
        var issues: [String] = []
        if cpu > 80 { score -= (cpu - 80) * 1.2; issues.append("processeur très sollicité") }
        if ramPercent > 90 { score -= (ramPercent - 90) * 2; issues.append("mémoire presque pleine") }
        if diskPercent > 85 { score -= (diskPercent - 85) * 2; issues.append("stockage presque plein") }
        switch thermal {
        case .serious: score -= 20; issues.append("appareil chaud")
        case .critical: score -= 40; issues.append("surchauffe")
        default: break
        }
        if uptime > 7 * 86400 { score -= 5; issues.append("pas redémarré depuis plus d'une semaine") }
        let s = Int(max(0, min(100, score.rounded())))
        let g = s >= 90 ? "A" : s >= 75 ? "B" : s >= 60 ? "C" : s >= 40 ? "D" : "E"
        return (s, g, issues.isEmpty ? "Tout va bien, aucune action nécessaire." : "À surveiller : " + issues.joined(separator: ", ") + ".")
    }
}

@MainActor
final class LocalSystemMonitor: ObservableObject {
    @Published private(set) var stats: LocalStats?

    private var prevTicks: [UInt64]?
    private var prevNet: (date: Date, inBytes: UInt64, outBytes: UInt64)?
    private var history: [Double] = []
    private var timer: Timer?

    var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "ce Mac"
        #else
        return "cet iPhone"
        #endif
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func sample() {
        let cpu = cpuUsage()
        history.append(cpu)
        if history.count > 90 { history.removeFirst(history.count - 90) }
        let (ramUsed, ramTotal) = memory()
        let (diskUsed, diskTotal) = disk()
        let net = network()
        stats = LocalStats(cpu: cpu, ramUsedGB: ramUsed, ramTotalGB: ramTotal, diskUsedGB: diskUsed,
                           diskTotalGB: diskTotal, upKBs: net.up, downKBs: net.down, sentGB: net.sent,
                           recvGB: net.recv, uptime: ProcessInfo.processInfo.systemUptime,
                           thermal: ProcessInfo.processInfo.thermalState, history: history)
    }

    // MARK: - Mesures

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks  // utilisateur, système, inactif, nice
        let ticks = [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
        defer { prevTicks = ticks }
        guard let prev = prevTicks else { return 0 }
        let d = zip(ticks, prev).map { $0 >= $1 ? $0 - $1 : 0 }
        let total = d.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(total - d[2]) / Double(total) * 100
    }

    private func memory() -> (Double, Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = Double(getpagesize())
        let usedPages = Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
        return (min(total, usedPages * page / 1_073_741_824), total)
    }

    private func disk() -> (Double, Double) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity else { return (0, 0) }
        let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        let t = Double(total)
        return ((t - free) / 1_000_000_000, t / 1_000_000_000)
    }

    private func network() -> (up: Double, down: Double, sent: Double, recv: Double) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0, 0, 0) }
        defer { freeifaddrs(addrs) }
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    inBytes += UInt64(d.ifi_ibytes)
                    outBytes += UInt64(d.ifi_obytes)
                }
            }
            cursor = ifa.ifa_next
        }
        let now = Date()
        var up = 0.0, down = 0.0
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0 {
                down = Double(inBytes >= prev.inBytes ? inBytes - prev.inBytes : 0) / dt / 1024
                up = Double(outBytes >= prev.outBytes ? outBytes - prev.outBytes : 0) / dt / 1024
            }
        }
        prevNet = (now, inBytes, outBytes)
        return (up, down, Double(outBytes) / 1_073_741_824, Double(inBytes) / 1_073_741_824)
    }
}
