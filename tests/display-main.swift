import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

// 覆盖本模块使用的系统调用；这些测试不访问 WindowServer。
func CGGetOnlineDisplayList(_ max: UInt32, _ ids: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>?) -> CGError {
    if ConfigurationSimulation.queryFails { return .failure }
    let values = Array(DisplaySimulation.online).sorted()
    count?.pointee = UInt32(values.count)
    if let ids { for (index, value) in values.prefix(Int(max)).enumerated() { ids[index] = value } }
    return .success
}
func CGDisplayVendorNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.vendorID ?? 0 }
func CGDisplayModelNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.productID ?? 0 }
func CGDisplaySerialNumber(_ id: CGDirectDisplayID) -> UInt32 { DisplaySimulation.descriptors[id]?.serialNum ?? 0 }
func CGDisplayBounds(_ id: CGDirectDisplayID) -> CGRect {
    CGRect(origin: ConfigurationSimulation.origins[id] ?? CGPoint(x: id == 1 ? 0 : 1200, y: 0),
           size: CGSize(width: 1200, height: 800))
}
@discardableResult func CGConfigureDisplayOrigin(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ x: Int32, _ y: Int32) -> CGError {
    if ConfigurationSimulation.configureError != .success { return ConfigurationSimulation.configureError }
    ConfigurationSimulation.staged[display] = CGPoint(x: Int(x), y: Int(y))
    return .success
}
enum ConfigurationSimulation {
    static var failNext = false
    static var queryFails = false
    static var configureError = CGError.success
    static var response = CGError.success
    static var layoutChangeResponse: CGError?
    static var origins: [UInt32: CGPoint] = [:]
    static var staged: [UInt32: CGPoint] = [:]
    static var transactions: [(time: TimeInterval, origins: [UInt32: CGPoint], error: CGError)] = []
}
func applyDisplayConfig(_ work: (CGDisplayConfigRef?) -> CGError) -> CGError {
    ConfigurationSimulation.staged = [:]
    let configure = work(nil)
    let changesLayout = ConfigurationSimulation.staged.contains { CGDisplayBounds($0.key).origin != $0.value }
    let response = changesLayout ? (ConfigurationSimulation.layoutChangeResponse ?? ConfigurationSimulation.response) : ConfigurationSimulation.response
    let error = configure != .success ? configure : (ConfigurationSimulation.failNext ? .failure : response)
    ConfigurationSimulation.failNext = false
    if error == .success {
        ConfigurationSimulation.origins.merge(ConfigurationSimulation.staged) { _, new in new }
    }
    ConfigurationSimulation.transactions.append((DisplaySimulation.time, ConfigurationSimulation.staged, error))
    return error
}
enum Log { static func info(_ message: String) {} }
enum PhysicalDisplays {
    static var pending: [CGDirectDisplayID]?
    static var restoreFails = false
    static var restoreError = CGError.success
    static var restoreAttempts: [TimeInterval] = []
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError { pending = ids; return .success }
    static func restore(reason: String) -> CGError {
        restoreAttempts.append(DisplaySimulation.time)
        if restoreFails { return .failure }
        if restoreError != .success { return restoreError }
        pending = nil
        return .success
    }
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
        // 先交付后台事务回调，不能在事务尚未完成时跳到几分钟后的旧重试计时。
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        if let index = tasks.indices.min(by: { tasks[$0].0 < tasks[$1].0 }) {
            if !manager.isSettled && tasks[index].0 - DisplaySimulation.time > 1.5 { return }
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

        // 系统已经自动还原布局时，不提交冗余事务。
        func recoveryDriver(_ name: String, origin: [Int]) throws -> Driver {
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["1": origin]).write(to: path.appendingPathComponent("session.json"))
            return Driver(directory: path)
        }
        let unchangedDriver = try recoveryDriver("unchanged", origin: [0, 0])
        let transactionsBefore = ConfigurationSimulation.transactions.count
        unchangedDriver.manager.recoverIfNeeded()
        unchangedDriver.settle()
        precondition(ConfigurationSimulation.transactions.count == transactionsBefore)
        precondition(!FileManager.default.fileExists(atPath: unchangedDriver.directory.appendingPathComponent("session.json").path))

        // 普通还原失败也要保留记录，后续成功后才能删除。
        let retryDriver = try recoveryDriver("retry", origin: [80, 40])
        let retryMarker = retryDriver.directory.appendingPathComponent("session.json")
        ConfigurationSimulation.response = .failure
        retryDriver.manager.recoverIfNeeded()
        retryDriver.until { ConfigurationSimulation.transactions.count == transactionsBefore + 1 && retryDriver.manager.isSettled }
        precondition(FileManager.default.fileExists(atPath: retryMarker.path))
        ConfigurationSimulation.response = .success
        retryDriver.until { !FileManager.default.fileExists(atPath: retryMarker.path) && retryDriver.manager.isSettled }
        precondition(CGDisplayBounds(1).origin == CGPoint(x: 80, y: 40))
        ConfigurationSimulation.origins[1] = .zero

        // 还原超时后保留记录；冷却期间不建屏，失败检查退避，查询失败不算恢复。
        let protectedDriver = try recoveryDriver("protected", origin: [80, 40])
        let protectedMarker = protectedDriver.directory.appendingPathComponent("session.json")
        let createdBeforeProtection = DisplaySimulation.creations.count
        var notifications = 0
        protectedDriver.manager.onChange = { notifications += 1 }
        ConfigurationSimulation.response = CGError(rawValue: 1014)!
        protectedDriver.manager.recoverIfNeeded()
        protectedDriver.until { protectedDriver.manager.wedged && protectedDriver.manager.isSettled }
        precondition(notifications > 0 && FileManager.default.fileExists(atPath: protectedMarker.path))
        let timeoutIndex = ConfigurationSimulation.transactions.count - 1
        protectedDriver.manager.create(a)
        protectedDriver.manager.create(b)
        protectedDriver.manager.create(c)
        precondition(DisplaySimulation.creations.count == createdBeforeProtection)
        ConfigurationSimulation.response = .cannotComplete
        protectedDriver.until { ConfigurationSimulation.transactions.count == timeoutIndex + 2 && protectedDriver.manager.isSettled }
        let failedCheck = ConfigurationSimulation.transactions.last!
        precondition(failedCheck.time - ConfigurationSimulation.transactions[timeoutIndex].time >= 30)
        precondition(protectedDriver.manager.wedged && DisplaySimulation.creations.count == createdBeforeProtection)
        ConfigurationSimulation.response = .success
        protectedDriver.until { ConfigurationSimulation.transactions.count == timeoutIndex + 3 && protectedDriver.manager.isSettled }
        let firstSuccess = ConfigurationSimulation.transactions.last!
        precondition(firstSuccess.time - failedCheck.time >= 60)
        precondition(firstSuccess.origins == [1: .zero])
        precondition(protectedDriver.manager.wedged)

        ConfigurationSimulation.queryFails = true
        protectedDriver.tick()
        protectedDriver.until { protectedDriver.manager.isSettled }
        precondition(ConfigurationSimulation.transactions.count == timeoutIndex + 3 && protectedDriver.manager.wedged)
        ConfigurationSimulation.queryFails = false
        // 暂存原点失败即使服务器可提交事务，也不能被判为健康。
        ConfigurationSimulation.configureError = .failure
        protectedDriver.until { ConfigurationSimulation.transactions.count == timeoutIndex + 4 && protectedDriver.manager.isSettled }
        precondition(protectedDriver.manager.wedged)
        ConfigurationSimulation.configureError = .success
        protectedDriver.until { ConfigurationSimulation.transactions.count == timeoutIndex + 5 && protectedDriver.manager.isSettled }
        precondition(protectedDriver.manager.wedged && FileManager.default.fileExists(atPath: protectedMarker.path))
        protectedDriver.until { !protectedDriver.manager.wedged && protectedDriver.manager.current == c && protectedDriver.manager.isSettled }
        precondition(DisplaySimulation.creations.count == createdBeforeProtection + 1)
        precondition(CGDisplayBounds(1).origin == CGPoint(x: -1120, y: 40))
        protectedDriver.disconnect()
        precondition(CGDisplayBounds(1).origin == CGPoint(x: 80, y: 40))
        ConfigurationSimulation.origins[1] = .zero

        // 超时发生在建屏/设主屏阶段时，服务确认恢复前不能释放或创建对象。
        let releasesBefore = DisplaySimulation.releases.count
        ConfigurationSimulation.response = CGError(rawValue: 1014)!
        driver.manager.create(a)
        driver.until { driver.manager.wedged && driver.manager.isSettled }
        let createdDuringTimeout = DisplaySimulation.creations.count
        driver.manager.create(b)
        precondition(DisplaySimulation.creations.count == createdDuringTimeout && DisplaySimulation.releases.count == releasesBefore)
        // 物理屏兜底失败会退避，手动恢复可以绕过等待。
        PhysicalDisplays.pending = [1]
        PhysicalDisplays.restoreFails = true
        let restoreCount = PhysicalDisplays.restoreAttempts.count
        driver.manager.restorePhysicalNow()
        driver.until { PhysicalDisplays.restoreAttempts.count == restoreCount + 1 && driver.manager.isSettled }
        precondition(PhysicalDisplays.pending != nil && DisplaySimulation.releases.count == releasesBefore)
        PhysicalDisplays.restoreFails = false
        driver.manager.restorePhysicalNow()
        driver.until { PhysicalDisplays.pending == nil && driver.manager.isSettled }
        precondition(PhysicalDisplays.restoreAttempts.count == restoreCount + 2)
        ConfigurationSimulation.response = .success
        let healthCount = ConfigurationSimulation.transactions.count
        driver.until { ConfigurationSimulation.transactions.count == healthCount + 1 && driver.manager.isSettled }
        precondition(driver.manager.wedged && DisplaySimulation.releases.count == releasesBefore)
        driver.until { !driver.manager.wedged && driver.manager.current == b && driver.manager.isSettled }
        driver.disconnect()

        // 保护状态可立即结束退出收尾，保留布局记录；已排队的检查不会在退出后继续执行。
        let exitDriver = try recoveryDriver("exit", origin: [120, 60])
        ConfigurationSimulation.response = CGError(rawValue: 1014)!
        exitDriver.manager.recoverIfNeeded()
        exitDriver.until { exitDriver.manager.wedged && exitDriver.manager.isSettled }
        let exitTransactions = ConfigurationSimulation.transactions.count
        var exited = false
        exitDriver.manager.remove { exited = true }
        precondition(exited && FileManager.default.fileExists(atPath: exitDriver.directory.appendingPathComponent("session.json").path))
        exitDriver.tick()
        precondition(ConfigurationSimulation.transactions.count == exitTransactions)
        ConfigurationSimulation.response = .success

        // 物理屏恢复阶段的原始超时码也必须进入保护状态，而不是按普通失败无限重试。
        let physicalDriver = try recoveryDriver("physical-timeout", origin: [0, 0])
        PhysicalDisplays.pending = [1]
        PhysicalDisplays.restoreError = CGError(rawValue: 1014)!
        physicalDriver.manager.recoverIfNeeded()
        physicalDriver.until { physicalDriver.manager.wedged && physicalDriver.manager.isSettled }
        precondition(PhysicalDisplays.pending != nil)
        PhysicalDisplays.restoreError = .success
        physicalDriver.manager.restorePhysicalNow()
        physicalDriver.until { PhysicalDisplays.pending == nil && physicalDriver.manager.isSettled }
        physicalDriver.until { !physicalDriver.manager.wedged && physicalDriver.manager.isSettled }
        precondition(!FileManager.default.fileExists(atPath: physicalDriver.directory.appendingPathComponent("session.json").path))

        // 手动恢复成功后，已有的 5 分钟退避计时不能挡住间隔 5 秒的确认检查。
        let timerDriver = try recoveryDriver("timer-priority", origin: [80, 40])
        ConfigurationSimulation.response = CGError(rawValue: 1014)!
        timerDriver.manager.recoverIfNeeded()
        timerDriver.until { timerDriver.manager.wedged && timerDriver.manager.isSettled }
        PhysicalDisplays.pending = [1]
        PhysicalDisplays.restoreFails = true
        let timerRestores = PhysicalDisplays.restoreAttempts.count
        timerDriver.manager.restorePhysicalNow()
        timerDriver.until { PhysicalDisplays.restoreAttempts.count >= timerRestores + 6 && timerDriver.manager.isSettled }
        PhysicalDisplays.restoreFails = false
        ConfigurationSimulation.response = .success
        let timerChecks = ConfigurationSimulation.transactions.count
        timerDriver.manager.restorePhysicalNow()
        timerDriver.until { !timerDriver.manager.wedged && timerDriver.manager.isSettled }
        let confirmationGap = ConfigurationSimulation.transactions[timerChecks + 1].time - ConfigurationSimulation.transactions[timerChecks].time
        precondition(confirmationGap >= 5 && confirmationGap < 10, "Stale backoff timer delayed health confirmation")
        ConfigurationSimulation.origins[1] = .zero

        // 相同布局检查成功不代表真正切屏一定成功；反复失败时最多自动恢复两轮。
        let boundedDriver = try recoveryDriver("bounded-recovery", origin: [80, 40])
        ConfigurationSimulation.layoutChangeResponse = CGError(rawValue: 1014)!
        let boundedStart = ConfigurationSimulation.transactions.count
        boundedDriver.manager.recoverIfNeeded()
        boundedDriver.until { boundedDriver.manager.recoveryNeedsRestart && boundedDriver.manager.isSettled }
        let boundedTransactions = Array(ConfigurationSimulation.transactions.dropFirst(boundedStart))
        precondition(boundedDriver.manager.wedged && boundedTransactions.filter { $0.error.rawValue == 1014 }.count == 3)
        precondition(boundedTransactions.count == 7)
        precondition(FileManager.default.fileExists(atPath: boundedDriver.directory.appendingPathComponent("session.json").path))
        let stoppedTransactions = ConfigurationSimulation.transactions.count
        boundedDriver.manager.remove()
        boundedDriver.tick()
        precondition(ConfigurationSimulation.transactions.count == stoppedTransactions)
        ConfigurationSimulation.layoutChangeResponse = nil
        precondition(Set(DisplaySimulation.creations.map(\.serial)) == Set(VirtualDisplayIdentityPool.serials))
        precondition(Set(DisplaySimulation.creations.map(\.name)) == ["UUyc companion"])
        precondition(DisplaySimulation.releases.count == DisplaySimulation.creations.count)
        print("PASS: display lifecycle, 30 reconnect cycles, redundant layout avoidance, retained recovery records, timeout protection, health-check backoff, two consecutive successes, manual physical recovery and shutdown")
    }
}
