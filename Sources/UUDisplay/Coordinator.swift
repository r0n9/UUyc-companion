// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor = UUMonitor()
    let display = DisplayManager()
    private let store = ConfigStore.shared
    private let audioReconnect: AudioReconnectWindow
    private var audioRecoveryError: String?

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var namePoll: Timer?
    private var connectedAt = Date.distantPast
    private var openedUUWindow = false

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    init(audioReconnect: AudioReconnectWindow = AudioReconnectWindow()) {
        self.audioReconnect = audioReconnect
        audioReconnect.onExpire = { [weak self] wasDisconnected in
            guard let self else { return }
            if wasDisconnected {
                self.namePoll?.invalidate()
                self.namePoll = nil
                self.display.remove()
                Log.info("声音恢复重连窗口已到期，恢复物理屏并收尾虚拟屏")
            }
            self.onChange?()
        }
    }

    var audioRecoveryStatus: AudioRecoveryStatus {
        AudioRecoveryStatus(available: connected && !store.config.paused && physicalDisableAllowed
                            && display.physicalOff && display.canRetainForReconnect && !audioReconnect.isArmed,
                            remainingSeconds: audioReconnect.remainingSeconds,
                            waitingForReconnect: audioReconnect.waitingForReconnect, error: audioRecoveryError)
    }

    func beginAudioRecovery() {
        guard audioRecoveryStatus.available, let id = display.activeDisplayID else { return }
        audioRecoveryError = nil
        if audioReconnect.begin(displayID: id) {
            Log.info("声音恢复：保留虚拟屏 #\(id) 15 秒，请在控制端断开并重新连接")
        } else {
            audioRecoveryError = "未能准备重连窗口，请稍后重试。"
            Log.info("无法保存声音恢复重连记录，保留正常断开行为")
        }
        onChange?()
    }

    private func cancelAudioRecovery() {
        if audioReconnect.cancel() { display.remove() }
        audioRecoveryError = nil
    }

    func start() {
        display.onChange = { [weak self] in
            guard let self else { return }
            if self.audioReconnect.isArmed,
               self.display.wedged || !self.display.physicalOff || self.display.activeDisplayID != self.audioReconnect.lease?.displayID {
                self.cancelAudioRecovery()
            }
            self.onChange?()
        }
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.start()
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.recoveryNeedsRestart { return "⚠️ 屏幕调整反复失败，请退出并重新打开应用" }
        if display.wedged { return "⚠️ 屏幕调整已暂停，正在等待系统恢复" }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        if audioReconnect.isArmed {
            return "虚拟屏保留中 · 剩余 \(audioReconnect.remainingSeconds) 秒 · 请在控制端断开并重新连接"
        }
        guard connected else { return "等待其它设备连接中" }
        let who = controllerName ?? "未知设备"
        if let c = display.current, display.isActive {
            return "\(who) 已连接 · 虚拟屏已匹配 \(c.sizeLabel)\(display.physicalOff ? " · 物理屏幕已软关闭" : "")"
        }
        return "\(who) 已连接 · 虚拟屏没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        connectedAt = Date()
        controllerName = nil
        openedUUWindow = false
        onChange?()
        guard !store.config.paused else { return }
        if pollName() { return }
        namePoll?.invalidate()
        namePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.pollName() { t.invalidate() }
        }
    }

    func handleDisconnect() {
        namePoll?.invalidate()
        namePoll = nil
        if !store.config.paused, physicalDisableAllowed, display.physicalOff, display.canRetainForReconnect,
           audioReconnect.holdOnDisconnect(displayID: display.activeDisplayID) {
            Log.info("声音恢复：远程已断开，暂时保留同一虚拟屏等待重连")
        } else {
            audioReconnect.cancel()
            display.remove()
        }
        controllerName = nil
        onChange?()
    }

    /// 返回 true 表示已拿到名称、无需继续轮询
    private func pollName() -> Bool {
        guard connected, !store.config.paused else { return true }
        let elapsed = Date().timeIntervalSince(connectedAt)

        if let name = simulatedName ?? readControllerName() {
            resolve(name)
            return true
        }
        if elapsed >= 30 {
            Log.info("30 秒内未读到控制端名称，停止等待")
            return true
        }
        return false
    }

    private func readControllerName() -> String? {
        guard UUReader.isTrusted else { return nil }
        switch UUReader.readControllers() {
        case .none:
            // 主窗口没开：打开一次 UU 主界面再读
            if !openedUUWindow {
                openedUUWindow = true
                Log.info("UU 主窗口未打开，尝试打开以读取控制端名称")
                UUReader.showMainWindow()
            }
            return nil
        case .some(let names):
            return names.first
        }
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            Log.info("「\(name)」不在设备列表里，不调整")
        }
        if audioReconnect.isArmed {
            if let cfg, cfg.kind != .computer, cfg.hasSize, display.matches(cfg), display.canRetainForReconnect, display.physicalOff,
               audioReconnect.lease?.displayID == display.activeDisplayID, audioReconnect.remainingSeconds > 0 {
                if audioReconnect.completeReconnect(displayID: display.activeDisplayID) {
                    Log.info("声音恢复：重连已匹配原虚拟屏，请在控制端确认声音")
                }
            } else {
                cancelAudioRecovery()
            }
        }
        apply(cfg)
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            if display.isActive { display.remove() }
            Log.info(cfg == nil ? "无可用配置，不切换" : "「\(cfg!.name)」不指定分辨率或还没填写，不切换")
            return
        }
        if display.matches(cfg) { return }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            cancelAudioRecovery()
            namePoll?.invalidate()
            display.remove()
        } else if connected {
            handleConnect()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        cancelAudioRecovery()
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) } else { handleConnect() }
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        cancelAudioRecovery()
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        cancelAudioRecovery()
        store.config.disablePhysical = on
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        audioReconnect.cancel()
        display.remove(completion: completion)
    }
}
