import Foundation
import CoreFoundation

// 不访问真实 UU 或显示器，只替代 monitor 默认依赖。
enum UUReader {
    static var isTrusted: Bool { false }
    static func readControllers() -> [String]? { nil }
}
enum Log { static func info(_ message: String) {} }

// 兼容旧 SDK 的 CFString 别名与新 SDK 的 CFRunLoopMode 包装类型。
private func runLoopMode(_ name: CFString, as type: CFString.Type) -> CFString { name }
private func runLoopMode<Mode: RawRepresentable>(_ name: CFString, as type: Mode.Type) -> Mode where Mode.RawValue == CFString {
    guard let mode = Mode(rawValue: name) else { preconditionFailure("Invalid run loop mode") }
    return mode
}

@main struct MonitorTests {
    static func main() {
        let lock = NSLock()
        var reads = 0
        var overlay = true
        var connects = 0
        var disconnects = 0
        var pulses = 0
        let monitor = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); reads += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 3)
            return ["stale controller"]
        }, hasOverlay: { overlay })
        monitor.onConnect = { connects += 1 }
        monitor.onDisconnect = { disconnects += 1 }
        monitor.start()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in pulses += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        precondition(connects == 1, "覆盖窗口检测不能等待 AX 返回")
        overlay = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        precondition(disconnects == 1, "AX 阻塞时仍应按覆盖窗口缺席触发断开")
        lock.lock(); let count = reads; lock.unlock()
        precondition(count == 1, "AX 读取不能堆积或并发")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        precondition(connects == 1, "过期的 AX 结果不能重新触发连接")
        precondition(pulses >= 30, "AX 读取不能阻塞主线程")
        heartbeat.invalidate()
        // 操作指引的模态窗口中，连接监测和同样注册在 common modes 的心跳仍可运行。
        let mode = RunLoop.Mode("NSModalPanelRunLoopMode")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), runLoopMode(mode.rawValue as CFString, as: CFRunLoopMode.self))
        var modalOverlay = true
        let modalMonitor = UUMonitor(trusted: { false }, hasOverlay: { modalOverlay })
        modalMonitor.start()
        precondition(modalMonitor.connected)
        var modalPulses = 0
        let commonHeartbeat = Timer(timeInterval: 0.05, repeats: true) { _ in modalPulses += 1 }
        RunLoop.main.add(commonHeartbeat, forMode: .common)
        modalOverlay = false
        let modalDeadline = Date().addingTimeInterval(1.9)
        while Date() < modalDeadline { RunLoop.main.run(mode: mode, before: modalDeadline) }
        precondition(!modalMonitor.connected && modalPulses >= 20, "操作指引显示时必须继续监测连接和维持心跳")
        commonHeartbeat.invalidate()
        print("PASS: blocked AX keeps main thread responsive; no overlapping reads; overlay disconnect; stale results; monitoring and common-mode heartbeat continue in modal guidance")
    }
}
