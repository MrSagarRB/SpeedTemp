import Cocoa
import ServiceManagement

// MARK: - Network speed

final class NetworkMonitor {
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastTime = Date()
    private var startIn: UInt64 = 0
    private var startOut: UInt64 = 0

    private(set) var downloadKBps: Double = 0
    private(set) var uploadKBps: Double = 0
    var totalDownloaded: UInt64 { lastIn &- startIn }
    var totalUploaded: UInt64 { lastOut &- startOut }

    init() {
        (lastIn, lastOut) = Self.readBytes()
        (startIn, startOut) = (lastIn, lastOut)
    }

    func update() {
        let (inB, outB) = Self.readBytes()
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        if dt > 0 {
            // Counters can reset (e.g. interface goes down); treat that as 0.
            downloadKBps = inB >= lastIn ? Double(inB - lastIn) / 1024 / dt : 0
            uploadKBps = outB >= lastOut ? Double(outB - lastOut) / 1024 / dt : 0
        }
        if inB < lastIn || outB < lastOut { (startIn, startOut) = (inB, outB) }
        (lastIn, lastOut, lastTime) = (inB, outB, now)
    }

    /// Sums 64-bit byte counters of physical interfaces (Wi-Fi, Ethernet, cellular).
    /// VPN tunnels and loopback are skipped so traffic isn't counted twice.
    static func readBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var inB: UInt64 = 0, outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            inB += msg.ifm_data.ifi_ibytes
                            outB += msg.ifm_data.ifi_obytes
                        }
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (inB, outB)
    }
}

// MARK: - Temperature (Apple Silicon HID sensors)

@_silgen_name("IOHIDEventSystemClientCreate")
private func hidClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func hidSetMatching(_ client: CFTypeRef, _ match: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func hidCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func hidCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func hidCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func hidEventFloat(_ event: CFTypeRef, _ field: Int32) -> Double

struct Temperatures {
    var cpu: Double?
    var gpu: Double?
    var soc: Double?
    var ssd: Double?
    var battery: Double?
}

final class TemperatureMonitor {
    private let kTemperatureEvent: Int64 = 15
    private var client: CFTypeRef? // must stay alive while services are used
    private var services: [(name: String, service: CFTypeRef)] = []
    private(set) var current = Temperatures()

    init() {
        guard let client = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Usage page 0xff00 / usage 5 = Apple vendor temperature sensors.
        _ = hidSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = hidCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        for s in list {
            let name = hidCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            services.append((name, s))
        }
    }

    func update() {
        var groups: [String: [Double]] = [:]
        for (name, s) in services {
            guard let event = hidCopyEvent(s, kTemperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = hidEventFloat(event, Int32(kTemperatureEvent << 16))
            guard value > 0, value < 130 else { continue } // drop bogus readings
            let key: String?
            if name.contains("pACC") || name.contains("eACC") || name.contains("CPU") { key = "cpu" }
            else if name.contains("GPU") { key = "gpu" }
            else if name.contains("SOC") || name.contains("tdie") { key = "soc" }
            else if name.contains("NAND") { key = "ssd" }
            else if name.contains("battery") { key = "battery" }
            else { key = nil }
            if let key { groups[key, default: []].append(value) }
        }
        func avg(_ k: String) -> Double? {
            guard let v = groups[k], !v.isEmpty else { return nil }
            return v.reduce(0, +) / Double(v.count)
        }
        current = Temperatures(cpu: avg("cpu") ?? avg("soc"), gpu: avg("gpu"), soc: avg("soc"),
                               ssd: avg("ssd"), battery: avg("battery"))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let net = NetworkMonitor()
    private let temp = TemperatureMonitor()
    private var tick = 0

    private let downItem = NSMenuItem()
    private let upItem = NSMenuItem()
    private let totalItem = NSMenuItem()
    private let cpuItem = NSMenuItem()
    private let gpuItem = NSMenuItem()
    private let socItem = NSMenuItem()
    private let ssdItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let thermalItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        temp.update()
        refresh()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common) // keep updating while the menu is open
    }

    private func buildMenu() {
        let menu = NSMenu()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        header("Network")
        [downItem, upItem, totalItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        header("Temperature")
        [cpuItem, gpuItem, socItem, ssdItem, batteryItem, thermalItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit SpeedTemp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refresh() {
        net.update()
        tick += 1
        if tick % 2 == 0 { temp.update() } // sensors change slowly; read every 2s

        let t = temp.current
        let tempText = t.cpu.map { String(format: "%.0f°C", $0) } ?? "--°C"
        let title = String(format: "↓ %@ KB/s  ↑ %@ KB/s  🌡 %@",
                           kb(net.downloadKBps), kb(net.uploadKBps), tempText)
        statusItem.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])

        downItem.title = "    Download:  \(kb(net.downloadKBps)) KB/s"
        upItem.title = "    Upload:  \(kb(net.uploadKBps)) KB/s"
        totalItem.title = "    Since start:  ↓ \(bytes(net.totalDownloaded))   ↑ \(bytes(net.totalUploaded))"

        cpuItem.title = "    CPU:  \(deg(t.cpu))"
        gpuItem.title = "    GPU:  \(deg(t.gpu))"
        socItem.title = "    SoC:  \(deg(t.soc))"
        ssdItem.title = "    SSD:  \(deg(t.ssd))"
        batteryItem.title = "    Battery:  \(deg(t.battery))"
        thermalItem.title = "    Thermal state:  \(thermalState())"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func kb(_ v: Double) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.maximumFractionDigits = v < 10 ? 1 : 0
        n.minimumFractionDigits = v < 10 ? 1 : 0
        return n.string(from: NSNumber(value: v)) ?? "0"
    }

    private func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .binary)
    }

    private func deg(_ v: Double?) -> String {
        v.map { String(format: "%.1f °C", $0) } ?? "n/a"
    }

    private func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
