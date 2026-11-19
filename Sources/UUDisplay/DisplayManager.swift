// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 调用方只声明「应该是什么样」（desired），执行器一次只做一步拓扑变化，每步之后等待系统稳定再做下一步。
// 原因（实测）：重新启用物理屏的热插拔事件尚未处理完时又新建虚拟屏，applySettings 失败，
//              随后 WindowServer 在 GenerateModeListForDisplay 中 abort，系统注销重启。
//      另：虚拟屏创建后约 1 秒、尚未完全上线时就释放，会让 WindowServer 显示配置卡死（所有事务 10 秒超时），
//      因此释放前必须已上线且存活 ≥ 2.5 秒；超时后暂停拓扑变化，配置服务连续响应后再恢复。
// 其他要点：虚拟屏只给一个模式且不改；GUI 主线程不能调 CGCompleteDisplayConfiguration（放 cgQueue）；
//          物理屏是否被禁用以磁盘记录为准（看门狗可能在别的进程里已恢复）。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

final class DisplayManager {
    static let vendorID = VirtualDisplayIdentityPool.vendorID

    // 目标状态
    private var desired: DeviceConfig?
    private var shutdownCompletion: (() -> Void)?
    /// 是否应禁用物理屏（由 Coordinator 按设置与看门狗状态决定）
    var shouldDisablePhysical: () -> Bool = { false }
    /// 异步显示状态变化时刷新菜单栏
    var onChange: (() -> Void)?
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false

    // 实际状态
    private var vd: CGVirtualDisplay?
    private(set) var current: DeviceConfig?
    private var mainSet = false
    /// 换设备时的旧屏，等新屏成为主屏后释放
    private var retiring: [CGVirtualDisplay] = []
    private var retiringConfig: DeviceConfig?
    /// 配置失败的虚拟屏，稳定后再释放（立即释放曾触发 WindowServer 崩溃）
    private var broken: [CGVirtualDisplay] = []
    /// 同一配置创建失败后不再重试，直到目标变化
    private var failedCfg: DeviceConfig?
    /// 建屏前各物理屏的原点，用于还原
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]

    // 执行器
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var displaySerials: [CGDirectDisplayID: UInt32] = [:]
    private var identities: VirtualDisplayIdentityPool?
    private var waitingForSlot = false
    private var releaseWaitStart: Date?
    private var shutdownFinished = false
    private var layoutRestoreRetryAt = Date.distantPast
    /// WindowServer 显示配置无响应（事务超时）：停止建屏/删屏/改布局
    private(set) var wedged = false
    private var retryAt: Date?
    private var retryGeneration = 0
    private var automaticRecoveryAttempts = 0
    private(set) var recoveryNeedsRestart = false
    private var nextHealthCheckAt = Date.distantPast
    private var nextPhysicalRestoreAt = Date.distantPast
    private var healthCheckDelay: TimeInterval = 30
    private var healthCheckSuccesses = 0
    static let minLifetime: TimeInterval = 2.5
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    private let identityURL: URL
    private let markerURL: URL
    private let now: () -> Date
    private let schedule: Scheduler
    private let onlineDisplayIDs: () -> [CGDirectDisplayID]?

    init(identityURL: URL = ConfigStore.dir.appendingPathComponent("display-identities.json"),
         markerURL: URL = ConfigStore.dir.appendingPathComponent("session.json"),
         now: @escaping () -> Date = Date.init,
         schedule: @escaping Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         onlineDisplayIDs: @escaping () -> [CGDirectDisplayID]? = DisplayManager.checkedOnlineDisplays) {
        self.identityURL = identityURL
        self.markerURL = markerURL
        self.now = now
        self.schedule = schedule
        self.onlineDisplayIDs = onlineDisplayIDs
    }

    var isActive: Bool { vd != nil }
    var isSettled: Bool { !busy }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        checkedOnlineDisplays() ?? []
    }

    private static func checkedOnlineDisplays() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID
    }

    private static func same(_ a: DeviceConfig?, _ b: DeviceConfig?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.width == b.width && a.height == b.height && a.hiDPI == b.hiDPI
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool { DisplayManager.same(desired, cfg) && vd != nil }

    // MARK: - 对外接口：只改目标状态

    func create(_ cfg: DeviceConfig) {
        shutdownFinished = false
        if !DisplayManager.same(desired, cfg) { failedCfg = nil }
        desired = cfg
        kick()
    }

    func remove(completion: (() -> Void)? = nil) {
        desired = nil
        failedCfg = nil
        physicalOverride = false
        nextPhysicalRestoreAt = .distantPast
        if let completion { shutdownCompletion = completion }
        kick()
    }

    func disablePhysicalIfNeeded() { kick() }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        nextPhysicalRestoreAt = .distantPast
        kick()
    }

    /// 启动时：读回上次未收尾的布局记录；残留的物理屏禁用记录由执行器按「目标=无」自动恢复
    func recoverIfNeeded() {
        if let data = try? Data(contentsOf: markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
            for (k, v) in dict where v.count == 2 {
                if let id = UInt32(k) { savedOrigins[id] = CGPoint(x: v[0], y: v[1]) }
            }
        }
        if !savedOrigins.isEmpty || physicalOff {
            Log.info("发现上次异常退出的残留状态，先恢复物理屏与显示器布局")
            recovering = true
        }
        kick()
    }

    // MARK: - 执行器

    private func kick() {
        guard !busy else { return }
        step()
    }

    /// 完成一步后等待 settle 秒再评估下一步
    private func finish(settle: TimeInterval) {
        schedule(settle) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.step()
            self.onChange?()
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, after: ((CGError) -> Void)? = nil, _ work: @escaping () -> CGError) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                if err == .cannotComplete || err.rawValue == 1014 { self.enterWedged(err) }
                after?(err)
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError) {
        guard !wedged else { return }
        wedged = true
        healthCheckDelay = 30
        healthCheckSuccesses = 0
        nextHealthCheckAt = now().addingTimeInterval(healthCheckDelay)
        nextPhysicalRestoreAt = .distantPast
        recoveryNeedsRestart = automaticRecoveryAttempts >= 2
        Log.info("⛔️ 显示配置超时（CGError=\(err.rawValue)），暂停屏幕调整；稍后检查系统是否恢复")
        if recoveryNeedsRestart {
            Log.info("自动恢复后屏幕调整再次超时，停止继续自动恢复；请退出并重新打开应用，持续失败时再注销或重启 Mac")
        }
        onChange?()
    }

    /// 长时间等待不占用 busy，手动恢复物理屏和退出仍可立即处理。
    private func scheduleRetry(at date: Date) {
        // 新目标需要更早检查时替换原计时，旧回调通过代次失效。
        if let retryAt, retryAt <= date { return }
        retryAt = date
        retryGeneration += 1
        let generation = retryGeneration
        schedule(max(0, date.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.retryGeneration == generation else { return }
            self.retryAt = nil
            self.kick()
        }
    }

    private func stepProtected() {
        if physicalOff {
            guard now() >= nextPhysicalRestoreAt else {
                return scheduleRetry(at: nextPhysicalRestoreAt)
            }
            return runCG(settle: 1.5, after: { [weak self] error in
                guard let self else { return }
                if error != .success {
                    self.healthCheckSuccesses = 0
                    self.nextPhysicalRestoreAt = self.now().addingTimeInterval(self.healthCheckDelay)
                    self.healthCheckDelay = min(self.healthCheckDelay * 2, 300)
                }
            }) { PhysicalDisplays.restore(reason: "保护状态") }
        }
        if let done = shutdownCompletion {
            shutdownCompletion = nil
            shutdownFinished = true
            done()
            return
        }
        guard !recoveryNeedsRestart else { return }
        guard now() >= nextHealthCheckAt else {
            return scheduleRetry(at: nextHealthCheckAt)
        }
        return runCG(settle: 1.5, after: { [weak self] error in
            guard let self else { return }
            if error == .success {
                self.healthCheckSuccesses += 1
                if self.healthCheckSuccesses >= 2 {
                    self.automaticRecoveryAttempts += 1
                    self.wedged = false
                    self.recovering = true
                    self.failedCfg = nil
                    Log.info("✅ 显示配置服务连续两次响应，先恢复残留布局，再应用当前连接配置")
                    self.onChange?()
                } else {
                    self.nextHealthCheckAt = self.now().addingTimeInterval(5)
                }
            } else {
                self.healthCheckSuccesses = 0
                self.healthCheckDelay = min(self.healthCheckDelay * 2, 300)
                self.nextHealthCheckAt = self.now().addingTimeInterval(self.healthCheckDelay)
                Log.info("显示配置服务尚未恢复（CGError=\(error.rawValue)），\(Int(self.healthCheckDelay)) 秒后再检查；持续无响应可注销或重启 Mac")
            }
        }) { DisplayManager.checkConfigurationResponse() }
    }

    /// 释放前确认每块屏已上线且存活足够久；最多等 8 秒
    private func readyToRelease(_ displays: [CGVirtualDisplay], online: Set<CGDirectDisplayID>) -> Bool {
        let young = displays.contains { d in
            !online.contains(d.displayID) || now().timeIntervalSince(bornAt[d.displayID] ?? .distantPast) < DisplayManager.minLifetime
        }
        guard young else { releaseWaitStart = nil; return true }
        let start = releaseWaitStart ?? now()
        releaseWaitStart = start
        if now().timeIntervalSince(start) > 8 { releaseWaitStart = nil; return true }
        return false
    }

    private func rejectCurrentDisplay() {
        failedCfg = current
        if let failed = vd { broken.append(failed) }
        vd = retiring.popLast()
        current = retiringConfig
        retiringConfig = nil
        mainSet = vd != nil
    }

    private func step() {
        guard !busy, !shutdownFinished else { return }
        if wedged { return stepProtected() }

        // 断开或用户要求恢复时优先处理物理屏，不能被身份等待/失败回收挡住。
        if physicalOff, desired == nil || recovering || physicalOverride || !shouldDisablePhysical() {
            return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "远程结束或手动恢复") }
        }

        // 查询失败不能当作“全部离线”，否则可能重用系统仍占用的序列号。
        guard let onlineIDs = onlineDisplayIDs() else {
            busy = true
            return finish(settle: 1)
        }
        let online = Set(onlineIDs)
        identities?.reconcile(onlineDisplayIDs: online)

        // 1. 配置失败的屏：稳定后释放
        if !broken.isEmpty {
            guard readyToRelease(broken, online: online) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&broken)
            return finish(settle: 1.5)
        }

        guard let want = recovering ? nil : desired else {
            // 目标=无：恢复物理屏 → 释放虚拟屏 → 还原布局
            if physicalOff {
                return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "远程结束") }
            }
            if vd != nil || !retiring.isEmpty {
                guard readyToRelease(retiring + [vd].compactMap { $0 }, online: online) else { busy = true; return finish(settle: 0.5) }
                busy = true
                var all = retiring + [vd].compactMap { $0 }
                retiring = []
                retiringConfig = nil
                vd = nil
                current = nil
                mainSet = false
                release(&all)
                return finish(settle: 1.5)
            }
            if !savedOrigins.isEmpty {
                if identities?.hasPendingRemoval == true {
                    busy = true
                    return finish(settle: 0.5)
                }
                if now() < layoutRestoreRetryAt {
                    return scheduleRetry(at: layoutRestoreRetryAt)
                }
                let origins = savedOrigins
                return runCG(settle: 0.5, after: { [weak self] error in
                    guard let self else { return }
                    if error == .success {
                        self.savedOrigins = [:]
                        try? FileManager.default.removeItem(at: self.markerURL)
                    } else {
                        self.layoutRestoreRetryAt = self.now().addingTimeInterval(5)
                    }
                }) { DisplayManager.restoreOrigins(origins) }
            }
            if identities?.hasPendingRemoval == true {
                busy = true
                return finish(settle: 0.5)
            }
            if recovering {
                recovering = false
                Log.info("残留状态已恢复")
                if desired != nil { return step() }
            }
            automaticRecoveryAttempts = 0
            if let done = shutdownCompletion {
                shutdownCompletion = nil
                shutdownFinished = true
                done()
            }
            return
        }

        // 先完成已经开始的切换，避免连续配置变更累积第三块虚拟屏。
        if !mainSet, let id = vd?.displayID {
            guard online.contains(id) else {
                waitOnlineTries += 1
                if waitOnlineTries > 20 {
                    Log.info("⚠️ 虚拟屏 5 秒内未上线，保留旧屏并回收新屏")
                    rejectCurrentDisplay()
                }
                busy = true
                return finish(settle: 0.25)
            }
            if savedOrigins.isEmpty {
                savedOrigins = Dictionary(uniqueKeysWithValues: onlineIDs.filter { !DisplayManager.isVirtual($0) }
                    .map { ($0, CGDisplayBounds($0).origin) })
            }
            writeMarker()
            return runCG(settle: 0.5, after: { [weak self] error in
                guard let self, !self.wedged else { return }
                if error == .success { self.mainSet = true }
                else { self.rejectCurrentDisplay() }
            }) {
                let err = applyDisplayConfig { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in onlineIDs {
                        let o = CGDisplayBounds(d).origin
                        let error = CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                        if error != .success { return error }
                    }
                    return .success
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                return err
            }
        }

        if !retiring.isEmpty {
            guard readyToRelease(retiring, online: online) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&retiring)
            retiringConfig = nil
            return finish(settle: 1.5)
        }

        // 目标变化时先预留空闲身份；失败和槽位不足都保留现有屏幕。
        if (vd == nil || !DisplayManager.same(current, want)), !DisplayManager.same(failedCfg, want) {
            do {
                if identities == nil { identities = try VirtualDisplayIdentityPool(url: identityURL) }
            } catch {
                Log.info("❌ 无法读取或保存虚拟屏身份记录，停止建屏：\(error)")
                failedCfg = want
                return
            }
            let occupied = Set(onlineIDs.filter {
                CGDisplayVendorNumber($0) == Self.vendorID && CGDisplayModelNumber($0) == VirtualDisplayIdentityPool.productID
            }.map { CGDisplaySerialNumber($0) })
            guard let serial = identities?.reserve(occupiedSerials: occupied) else {
                if !waitingForSlot {
                    Log.info("等待虚拟屏身份槽位释放；不会生成新的随机身份")
                    waitingForSlot = true
                }
                busy = true
                return finish(settle: 1.5)
            }
            waitingForSlot = false
            busy = true
            if !createDisplay(want, serial: serial) { failedCfg = want }
            return finish(settle: 1.0)
        }

        let wantOff = shouldDisablePhysical() && !physicalOverride
        if wantOff, !physicalOff, let id = vd?.displayID {
            let physical = onlineIDs.filter { !DisplayManager.isVirtual($0) }
            if !physical.isEmpty {
                return runCG(settle: 1.5) {
                    let err = PhysicalDisplays.disable(physical)
                    Log.info(err == .success ? "✅ 已关闭物理屏 \(physical)，只保留虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
                    return err
                }
            }
        }
        if !wantOff, physicalOff {
            return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "手动恢复") }
        }
        // 完整切屏流程收敛后，才把本次连续故障计数清零。
        if mainSet, DisplayManager.same(current, want) { automaticRecoveryAttempts = 0 }
    }

    // MARK: - 单步操作

    private func createDisplay(_ cfg: DeviceConfig, serial: UInt32) -> Bool {
        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUyc companion"  // 身份和名称都复用，不随连接设备变化
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = VirtualDisplayIdentityPool.productID
        desc.serialNum = serial

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            identities?.cancelReservation(serial)
            Log.info("❌ 创建虚拟屏失败（serial=\(serial)，CGVirtualDisplay 返回 nil），保留现有屏幕")
            return false
        }
        displaySerials[display.displayID] = serial
        bornAt[display.displayID] = now()
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        guard let mode = CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60) else {
            broken.append(display)
            return false
        }
        settings.modes = [mode]
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败，稳定后释放")
            broken.append(display)
            return false
        }
        if let old = vd { retiring.append(old); retiringConfig = current }
        vd = display
        current = cfg
        mainSet = false
        waitOnlineTries = 0
        Log.info("✅ 已创建虚拟屏 #\(display.displayID) serial=\(serial) \(cfg.name) \(cfg.sizeLabel)")
        return true
    }

    private func release(_ displays: inout [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        let ids = displays.map { "#\($0.displayID)" }.joined(separator: " ")
        for display in displays {
            if let serial = displaySerials.removeValue(forKey: display.displayID) {
                identities?.awaitRemoval(serial: serial, displayID: display.displayID)
            }
            bornAt[display.displayID] = nil
        }
        autoreleasepool { displays.removeAll() }
        Log.info("已释放虚拟屏对象 \(ids)，身份槽位等待系统确认离线；历史 ColorSync 记录不在此处清理")
    }

    /// 空事务可能直接返回成功，必须提交当前原点才能检查实际的显示配置服务。
    /// 不创建屏幕、不切换模式；仅在保护状态下从 cgQueue 调用。
    private static func checkConfigurationResponse() -> CGError {
        guard let online = checkedOnlineDisplays(), !online.isEmpty else { return .failure }
        return applyDisplayConfig { cfg in
            for id in online {
                let origin = CGDisplayBounds(id).origin
                let error = CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
                if error != .success { return error }
            }
            return .success
        }
    }

    private static func restoreOrigins(_ origins: [CGDirectDisplayID: CGPoint]) -> CGError {
        guard let onlineIDs = checkedOnlineDisplays() else { return .failure }
        let online = Set(onlineIDs)
        let targets = origins.filter { online.contains($0.key) && CGDisplayBounds($0.key).origin != $0.value }
        guard !targets.isEmpty else { return .success }
        let err = applyDisplayConfig { cfg in
            for (id, o) in targets {
                let error = CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y))
                if error != .success { return error }
            }
            return .success
        }
        Log.info(err == .success ? "✅ 已还原显示器布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
        return err
    }

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedOrigins.map { ("\($0.key)", [$0.value.x, $0.value.y]) })
        try? JSONSerialization.data(withJSONObject: dict).write(to: markerURL, options: .atomic)
    }
}
