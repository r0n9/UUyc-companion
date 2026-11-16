import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

// 覆盖本模块使用的系统调用；这些测试不访问 WindowServer。
func CGGetOnlineDisplayList(_ max: UInt32, _ ids: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>?) -> CGError {
    let values = Array(DisplaySimulation.online).sorted()
    count?.pointee = UInt32(values.count)
    if let ids { for (index, value) in values.prefix(Int(max)).enumerated() { ids[index] = value } }
    return .success
}
func CGDisplayVendorNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.vendorID ?? 0 }
func CGDisplayModelNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.productID ?? 0 }
func CGDisplaySerialNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.serialNum ?? 0 }
func CGDisplayBounds(_ id: CGDirectDisplayID) -> CGRect { CGRect(x: 0, y: 0, width: 1200, height: 800) }
@discardableResult func CGConfigureDisplayOrigin(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ x: Int32, _ y: Int32) -> CGError { .success }
enum ConfigurationSimulation { static var failNext = false }
func applyDisplayConfig(_ work: (CGDisplayConfigRef?) -> Void) -> CGError {
    work(nil)
    if ConfigurationSimulation.failNext { ConfigurationSimulation.failNext = false; return .failure }
    return .success
}
enum Log { static func info(_ message: String) {} }
enum PhysicalDisplays {
    static var pending: [CGDirectDisplayID]?
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError { pending = ids; return .success }
    static func restore(reason: String) -> Bool { pending = nil; return true }
}

private final class Driver {
    private var tasks: [(TimeInterval, () -> Void)] = []
    var queryFails = false
    let directory: URL
    lazy var manager = DisplayManager(
        identityURL: directory.appendingPathComponent("identities.json"),
        markerURL: directory.appendingPathComponent("session.json"),
        now: { Date(timeIntervalSince1970: DisplaySimulation.time) },
        schedule: { [weak self] delay, work in self?.tasks.append((DisplaySimulation.time + delay, work)) },
        onlineDisplayIDs: { [weak self] in self?.queryFails == true ? nil : Array(DisplaySimulation.online) }
    )

    init(directory: URL) { self.directory = directory }
    func tick() {
        if let index = tasks.indices.min(by: { tasks[$0].0 < tasks[$1].0 }) {
            let (time, work) = tasks.remove(at: index)
            DisplaySimulation.advance(to: time)
            work()
        } else {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }
    func until(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        for _ in 0..<10000 {
            if predicate() { return }
            precondition(Date() < deadline, "Display lifecycle did not converge")
            tick()
        }
        preconditionFailure("Display lifecycle exceeded step limit")
    }
    func settle() {
        until { manager.isSettled }
    }
    func disconnect() {
        var done = false
        manager.remove { done = true }
        until { done }
        precondition(DisplaySimulation.live.isEmpty && DisplaySimulation.online == [1])
    }
}

@main struct DisplayTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let driver = Driver(directory: directory)
        let a = DeviceConfig(name: "iPad", kind: .tablet, width: 2360, height: 1640)
        let b = DeviceConfig(name: "phone", kind: .phone, width: 2400, height: 1080)
        let c = DeviceConfig(name: "changed", kind: .tablet, width: 3024, height: 1964, hiDPI: false)
        driver.manager.create(a)
        driver.settle()
        precondition(driver.manager.current == a && DisplaySimulation.live.count == 1)
        driver.manager.create(b)
        driver.manager.create(c)
        driver.settle()
        precondition(driver.manager.current == c && DisplaySimulation.live.count == 1)

        // CGVirtualDisplay 构造失败不能移走健康的旧屏，也不能无限重试。
        DisplaySimulation.constructorFailures = 1
        driver.manager.create(a)
        driver.settle()
        precondition(driver.manager.current == c && DisplaySimulation.live.count == 1)
        let failedAttempts = DisplaySimulation.attempts.count
        driver.manager.create(a)
        driver.settle()
        precondition(DisplaySimulation.attempts.count == failedAttempts)
        driver.manager.create(b)
        driver.settle()
        precondition(driver.manager.current == b)

        // applySettings 失败的对象仍占用槽位，并遵守最短存活时间。
        DisplaySimulation.applyFailures = 1
        driver.manager.create(c)
        driver.settle()
        precondition(driver.manager.current == b && DisplaySimulation.live.count == 1)
        driver.manager.create(a)
        driver.settle()
        precondition(driver.manager.current == a)

        ConfigurationSimulation.failNext = true
        driver.manager.create(c)
        driver.settle()
        precondition(driver.manager.current == a && DisplaySimulation.live.count == 1)

        // 未上线的新屏超时后回退到旧屏。
        DisplaySimulation.nextNeverOnline = true
        driver.manager.create(b)
        driver.settle()
        precondition(driver.manager.current == a && DisplaySimulation.live.count == 1)
        driver.disconnect()

        // 系统查询失败应停止建屏；失败不能被当成“离线”。
        driver.queryFails = true
        let before = DisplaySimulation.creations.count
        driver.manager.create(a)
        for _ in 0..<10 { driver.tick() }
        precondition(DisplaySimulation.creations.count == before)
        driver.queryFails = false
        driver.settle()

        // 槽位被其他进程占用时等待；手动恢复物理屏不能被等待挡住。
        let other = CGVirtualDisplayDescriptor()
        other.vendorID = VirtualDisplayIdentityPool.vendorID
        other.productID = VirtualDisplayIdentityPool.productID
        let activeSerial = DisplaySimulation.creations.last!.serial
        other.serialNum = VirtualDisplayIdentityPool.serials.first { $0 != activeSerial }!
        DisplaySimulation.descriptors[90] = other
        DisplaySimulation.online.insert(90)
        let attemptCount = DisplaySimulation.attempts.count
        driver.manager.create(b)
        for _ in 0..<10 { driver.tick() }
        precondition(DisplaySimulation.attempts.count == attemptCount)
        PhysicalDisplays.pending = [1]
        driver.manager.shouldDisablePhysical = { true }
        driver.manager.restorePhysicalNow()
        driver.until { PhysicalDisplays.pending == nil }
        DisplaySimulation.online.remove(90)
        DisplaySimulation.descriptors[90] = nil
        driver.manager.shouldDisablePhysical = { false }
        driver.settle()
        precondition(driver.manager.current == b)

        // 延迟撤销期间的快速重建不能借用仍在系统中的身份。
        DisplaySimulation.removalDelay = 7
        driver.manager.create(b)
        driver.settle()
        driver.manager.create(c)
        driver.settle()
        precondition(driver.manager.current == c)
        driver.disconnect()
        DisplaySimulation.removalDelay = 0

        for _ in 0..<30 {
            driver.manager.create(a)
            driver.settle()
            driver.manager.create(b)
            driver.manager.create(c)
            driver.settle()
            precondition(driver.manager.current == c && DisplaySimulation.live.count == 1)
            driver.disconnect()
        }
        let invalidDirectory = directory.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try Data("corrupt registry".utf8).write(to: invalidDirectory.appendingPathComponent("identities.json"))
        let invalidDriver = Driver(directory: invalidDirectory)
        let attemptsBefore = DisplaySimulation.attempts.count
        invalidDriver.manager.create(a)
        precondition(invalidDriver.manager.isSettled && !invalidDriver.manager.isActive)
        precondition(DisplaySimulation.attempts.count == attemptsBefore)
        precondition(Set(DisplaySimulation.creations.map(\.serial)) == Set(VirtualDisplayIdentityPool.serials))
        precondition(Set(DisplaySimulation.creations.map(\.name)) == ["UUyc companion"])
        precondition(DisplaySimulation.releases.count == DisplaySimulation.creations.count)
        print("PASS: display lifecycle converges through rapid changes, constructor/apply failures, offline timeout, query failure and delayed removal; 30 reconnect cycles stay within two identities")
    }
}
