import Foundation
import AVFoundation

// 编译实际 Coordinator 与重连状态机，替代 UU、显示器和用户配置，避免访问真实服务。
enum DeviceKind { case computer, tablet, phone }
struct DeviceConfig: Equatable {
    let name: String
    let kind: DeviceKind
    let width: Int
    let height: Int
    var hiDPI = true
    var hasSize: Bool { width > 0 && height > 0 }
    var sizeLabel: String { "\(width)×\(height)" }
}
struct AppConfig {
    var devices: [DeviceConfig] = []
    var paused = false
    var disablePhysical: Bool? = true
    var shouldDisablePhysical: Bool { disablePhysical ?? false }
}
final class ConfigStore {
    static let dir = FileManager.default.temporaryDirectory
    static let shared = ConfigStore()
    var config = AppConfig()
    func device(named name: String) -> DeviceConfig? { config.devices.first { $0.name == name } }
}
enum PhysicalDisplays { static var available = true }
enum Log { static func info(_ message: String) {} }
final class AudioCaptureMonitor {
    var status = AudioCaptureStatus()
    var onChange: (() -> Void)?
    var refreshes = 0
    func refresh() { refreshes += 1 }
    func updateContext(connected: Bool, displayID: UInt32?, onlyVirtual: Bool) {
        status = AudioCaptureStatus(kind: !connected ? .disconnected : (onlyVirtual ? .unknown : .physicalScreens))
    }
}
enum UUReader {
    static var isTrusted = true
    static var names: [String]?
    static func readControllers() -> [String]? { names }
    static func showMainWindow() {}
}
final class UUMonitor {
    var connected = false
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    func start() {}
}
final class DisplayManager {
    var onChange: (() -> Void)?
    var shouldDisablePhysical: () -> Bool = { false }
    var current: DeviceConfig?
    var activeDisplayID: UInt32?
    var physicalOff = false
    var wedged = false
    var recoveryNeedsRestart = false
    var isSettled = true
    var creations = 0
    var removals = 0
    var isActive: Bool { current != nil }
    var canRetainForReconnect: Bool { isActive && isSettled && !wedged }
    var onlyVirtualDisplaysOnline: Bool { isActive && physicalOff }
    func recoverIfNeeded() {}
    func matches(_ cfg: DeviceConfig) -> Bool {
        current?.width == cfg.width && current?.height == cfg.height && current?.hiDPI == cfg.hiDPI
    }
    func create(_ cfg: DeviceConfig) {
        creations += 1
        current = cfg
        activeDisplayID = UInt32(creations)
        physicalOff = shouldDisablePhysical()
        onChange?()
    }
    func remove(completion: (() -> Void)? = nil) {
        removals += 1
        current = nil
        activeDisplayID = nil
        physicalOff = false
        onChange?()
        completion?()
    }
    func restorePhysicalNow(override: Bool = true) { physicalOff = false; onChange?() }
    func disablePhysicalIfNeeded() { physicalOff = true; onChange?() }
}

private final class Clock {
    var uptime: TimeInterval = 100
    var tasks: [(TimeInterval, () -> Void)] = []
    func advance(_ seconds: TimeInterval) {
        let target = uptime + seconds
        while let index = tasks.indices.min(by: { tasks[$0].0 < tasks[$1].0 }), tasks[index].0 <= target {
            let (time, work) = tasks.remove(at: index)
            uptime = time
            work()
        }
        uptime = target
    }
}

private final class TestSoundPlayer: AudioTestSoundPlaying {
    enum Failure: Error { case unavailable }
    var onFinish: ((Bool) -> Void)?
    var plays = 0
    var stops = 0
    var fails = false
    func play() throws {
        plays += 1
        if fails { throw Failure.unavailable }
    }
    func stop() { stops += 1 }
}

private final class Fixture {
    let clock = Clock()
    let marker: URL
    let window: AudioReconnectWindow
    let coordinator: Coordinator
    init(directory: URL, writable: Bool = true) throws {
        let path = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        marker = writable ? path.appendingPathComponent("lease.json") : path
        let clock = self.clock
        window = AudioReconnectWindow(url: marker, pid: 123,
            now: { clock.uptime }, schedule: { delay, work in clock.tasks.append((clock.uptime + delay, work)) })
        ConfigStore.shared.config = AppConfig(devices: [
            DeviceConfig(name: "iPad", kind: .tablet, width: 2360, height: 1640),
            DeviceConfig(name: "phone", kind: .phone, width: 2400, height: 1080),
            DeviceConfig(name: "computer", kind: .computer, width: 0, height: 0)
        ])
        UUReader.names = nil
        coordinator = Coordinator(audioReconnect: window)
        coordinator.start()
        connect("iPad")
    }
    func connect(_ name: String) {
        coordinator.monitor.connected = true
        coordinator.simulatedName = name
        coordinator.handleConnect()
    }
    func disconnect() {
        coordinator.monitor.connected = false
        coordinator.simulatedName = nil
        coordinator.handleDisconnect()
    }
    func arm() {
        precondition(coordinator.audioRecoveryStatus.available)
        coordinator.beginAudioRecovery()
        precondition(window.isArmed && window.remainingSeconds == 15)
    }
}

@main struct AudioRecoveryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 解码内置音频但不播放到真实设备；测试播放与连接/恢复状态相互独立。
        let tone = AudioTestTone.waveData()
        let decoded = try AVAudioPlayer(data: tone, fileTypeHint: AVFileType.wav.rawValue)
        precondition(abs(decoded.duration - 4) < 0.01 && decoded.numberOfChannels == 2)
        precondition(tone.count == 44 + 4 * 44_100 * 4)
        var hasSignal = false
        for offset in stride(from: 44, to: tone.count, by: 4) {
            precondition(tone[offset] == tone[offset + 2] && tone[offset + 1] == tone[offset + 3])
            if tone[offset] != 0 || tone[offset + 1] != 0 { hasSignal = true }
        }
        precondition(hasSignal, "测试音必须包含可听信号，且左右声道均可试听")
        let sound = TestSoundPlayer()
        let soundClock = Clock()
        var soundRecovery = AudioRecoveryStatus(available: true)
        var soundCapture = AudioCaptureStatus(kind: .suspected)
        let soundModel = AudioRecoveryGuideModel(
            recoveryStatus: { soundRecovery }, captureStatus: { soundCapture },
            onStart: { soundRecovery = AudioRecoveryStatus(remainingSeconds: 15) },
            onStop: {}, onRefresh: {}, testSoundPlayer: sound, uptime: { soundClock.uptime })
        precondition(sound.plays == 0 && soundModel.canPlayTestSound)
        soundModel.playTestSound()
        let oldCompletion = sound.onFinish
        soundModel.playTestSound() // 播放中重复点击不会叠加声音。
        precondition(sound.plays == 1 && soundModel.testSoundState == .playing)
        soundClock.advance(1.2)
        soundModel.refresh()
        precondition(soundModel.testSoundRemainingSeconds == 3)
        soundModel.stopTestSound()
        precondition(sound.stops == 1 && soundModel.testSoundState == .stopped)
        soundModel.playTestSound()
        oldCompletion?(true)
        precondition(soundModel.testSoundState == .playing, "旧播放回调不能影响新的试听")
        sound.onFinish?(true)
        precondition(soundModel.testSoundState == .finished && soundModel.capture.kind == .suspected)
        precondition(soundModel.testSoundMessage.contains("如果控制设备听到了"))
        soundModel.playTestSound()
        soundModel.startRecovery()
        precondition(soundModel.testSoundState == .stopped && !soundModel.canPlayTestSound)
        let playsBeforeWaiting = sound.plays
        soundModel.playTestSound()
        precondition(sound.plays == playsBeforeWaiting)
        soundRecovery = AudioRecoveryStatus(available: true, outcome: .reconnected)
        soundModel.refresh()
        precondition(sound.plays == playsBeforeWaiting, "重连完成不自动播放")
        soundModel.playTestSound()
        soundCapture = AudioCaptureStatus(kind: .disconnected)
        soundModel.refresh()
        precondition(soundModel.testSoundState == .stopped && !soundModel.canPlayTestSound)
        soundCapture = AudioCaptureStatus(kind: .unknown)
        soundModel.playTestSound()
        soundModel.stopUpdating() // 与实际窗口关闭共用清理入口。
        precondition(soundModel.testSoundState == .stopped && sound.onFinish == nil)
        sound.fails = true
        soundModel.playTestSound()
        precondition(soundModel.testSoundState == .failed && soundModel.testSoundRemainingSeconds == 0)
        sound.fails = false
        soundModel.playTestSound()
        sound.onFinish?(false)
        precondition(soundModel.testSoundState == .failed && soundModel.canPlayTestSound)

        let normal = try Fixture(directory: root)
        normal.disconnect()
        precondition(normal.coordinator.display.removals == 1 && !normal.coordinator.display.isActive)

        // 查看和重复打开均不计时；开始后模型继续存在并更新步骤。
        let cancelledGuide = try Fixture(directory: root)
        cancelledGuide.coordinator.requestAudioRecovery()
        cancelledGuide.clock.advance(20)
        precondition(!cancelledGuide.window.isArmed && cancelledGuide.coordinator.display.removals == 0)
        let guideClock = Clock()
        let guideMarker = root.appendingPathComponent("guide-lease.json")
        let guideWindow = AudioReconnectWindow(url: guideMarker, pid: 123, now: { guideClock.uptime },
            schedule: { delay, work in guideClock.tasks.append((guideClock.uptime + delay, work)) })
        let guideCapture = AudioCaptureMonitor()
        let guideCoordinator = Coordinator(audioReconnect: guideWindow, audioCapture: guideCapture)
        var guideModel: AudioRecoveryGuideModel?
        guideCoordinator.onShowAudioRecovery = {
            if guideModel == nil {
                guideModel = AudioRecoveryGuideModel(
                    recoveryStatus: { guideCoordinator.audioRecoveryStatus },
                    captureStatus: { guideCoordinator.audioCaptureStatus },
                    onStart: { guideCoordinator.beginAudioRecovery() },
                    onStop: { guideCoordinator.stopAudioRecovery() },
                    onRefresh: { guideCoordinator.refreshAudioCapture() })
            }
        }
        guideCoordinator.start()
        guideCoordinator.simulatedName = "iPad"
        guideCoordinator.handleConnect()
        guideCoordinator.requestAudioRecovery()
        guideClock.advance(40)
        precondition(!guideWindow.isArmed && !FileManager.default.fileExists(atPath: guideMarker.path))
        guideModel?.startRecovery()
        precondition(guideWindow.remainingSeconds == 15 && guideWindow.lease?.startedAt == 140)
        let originalModel = guideModel
        guideCoordinator.requestAudioRecovery()
        precondition(guideModel === originalModel && guideWindow.remainingSeconds == 15)
        guideClock.advance(2)
        guideModel?.refresh()
        precondition(guideModel?.recovery.remainingSeconds == 13 && guideModel?.recovery.activeStep == 0)
        guideCapture.status = AudioCaptureStatus(kind: .suspected)
        guideModel?.refresh()
        precondition(guideModel?.capture.kind == .suspected)
        guideModel?.refreshCapture()
        precondition(guideCapture.refreshes == 1)
        guideModel?.stopRecovery()
        precondition(!guideWindow.isArmed && guideModel?.recovery.outcome == .cancelled)
        guideCoordinator.shutdown {}
        let changedDuringGuide = Coordinator(audioReconnect: guideWindow)
        changedDuringGuide.start()
        changedDuringGuide.simulatedName = "iPad"
        changedDuringGuide.handleConnect()
        let changedModel = AudioRecoveryGuideModel(
            recoveryStatus: { changedDuringGuide.audioRecoveryStatus }, captureStatus: { AudioCaptureStatus() },
            onStart: { changedDuringGuide.beginAudioRecovery() }, onStop: {}, onRefresh: {})
        PhysicalDisplays.available = false
        changedModel.startRecovery()
        precondition(!guideWindow.isArmed && !changedModel.recovery.available)
        PhysicalDisplays.available = true
        changedDuringGuide.shutdown {}

        let reconnect = try Fixture(directory: root)
        reconnect.arm()
        precondition(reconnect.coordinator.audioRecoveryStatus.instruction?.contains("第 1 步") == true)
        let original = reconnect.coordinator.display.activeDisplayID
        let lease = reconnect.window.lease!
        reconnect.coordinator.handleConnect() // 同一连接的名称刷新不能提前清除窗口。
        precondition(reconnect.window.isArmed)
        reconnect.clock.advance(3)
        reconnect.coordinator.beginAudioRecovery()
        precondition(reconnect.window.lease == lease && reconnect.window.remainingSeconds == 12)
        reconnect.disconnect()
        precondition(reconnect.coordinator.display.removals == 0 && reconnect.coordinator.display.physicalOff)
        precondition(reconnect.coordinator.audioRecoveryStatus.waitingForReconnect)
        precondition(reconnect.coordinator.audioRecoveryStatus.instruction?.contains("第 2 步") == true)
        reconnect.clock.advance(3)
        reconnect.connect("iPad")
        precondition(reconnect.coordinator.display.activeDisplayID == original && reconnect.coordinator.display.creations == 1)
        precondition(!reconnect.window.isArmed && !FileManager.default.fileExists(atPath: reconnect.marker.path))
        precondition(reconnect.coordinator.audioRecoveryStatus.instruction?.contains("第 3 步") == true)
        reconnect.coordinator.handleConnect()
        precondition(reconnect.coordinator.audioRecoveryStatus.instruction?.contains("第 3 步") == true)
        reconnect.clock.advance(20) // 已取消的到期回调不能拆掉新会话的屏幕。
        precondition(reconnect.coordinator.display.removals == 0)
        reconnect.disconnect()
        precondition(reconnect.coordinator.display.removals == 1)

        let timeout = try Fixture(directory: root)
        timeout.arm()
        timeout.disconnect()
        timeout.clock.advance(14.99)
        precondition(timeout.coordinator.display.removals == 0)
        timeout.clock.advance(0.01)
        precondition(timeout.coordinator.display.removals == 1 && !timeout.window.isArmed)
        timeout.connect("iPad")
        precondition(timeout.coordinator.display.creations == 2)

        let unchanged = try Fixture(directory: root)
        unchanged.arm()
        unchanged.clock.advance(15) // 未实际断开时只清除窗口，不调整显示器。
        precondition(!unchanged.window.isArmed && unchanged.coordinator.display.removals == 0)

        let changed = try Fixture(directory: root)
        changed.arm()
        changed.disconnect()
        changed.connect("phone")
        precondition(!changed.window.isArmed && changed.coordinator.display.creations == 2)
        precondition(changed.coordinator.display.current?.name == "phone")

        let unknown = try Fixture(directory: root)
        unknown.arm()
        unknown.disconnect()
        UUReader.names = ["unknown"]
        unknown.coordinator.monitor.connected = true
        unknown.coordinator.handleConnect()
        precondition(!unknown.window.isArmed && !unknown.coordinator.display.isActive)
        UUReader.names = nil

        let delayedName = try Fixture(directory: root)
        delayedName.arm()
        delayedName.disconnect()
        delayedName.coordinator.monitor.connected = true
        delayedName.coordinator.handleConnect()
        precondition(delayedName.coordinator.audioRecoveryStatus.confirmingReconnect)
        delayedName.clock.advance(15)
        precondition(!delayedName.coordinator.display.isActive)

        let cancelActions: [(Coordinator) -> Void] = [
            { $0.restorePhysical() }, { $0.setPaused(true) }, { $0.setDisablePhysical(false) },
            { $0.configChanged() }, { $0.shutdown {} }
        ]
        for action in cancelActions {
            let fixture = try Fixture(directory: root)
            fixture.arm()
            fixture.disconnect()
            action(fixture.coordinator)
            precondition(!fixture.window.isArmed && !fixture.coordinator.display.isActive)
            let removals = fixture.coordinator.display.removals
            fixture.clock.advance(20)
            precondition(fixture.coordinator.display.removals == removals)
        }
        let wedged = try Fixture(directory: root)
        wedged.arm()
        wedged.disconnect()
        wedged.coordinator.display.wedged = true
        wedged.coordinator.display.onChange?()
        precondition(!wedged.window.isArmed && !wedged.coordinator.display.isActive)

        let restoredElsewhere = try Fixture(directory: root)
        restoredElsewhere.arm()
        restoredElsewhere.disconnect()
        restoredElsewhere.coordinator.display.physicalOff = false
        restoredElsewhere.connect("iPad")
        precondition(!restoredElsewhere.window.isArmed && restoredElsewhere.coordinator.display.creations == 2)

        let failed = try Fixture(directory: root, writable: false)
        failed.coordinator.beginAudioRecovery()
        precondition(!failed.window.isArmed && failed.coordinator.audioRecoveryStatus.error != nil)
        failed.disconnect()
        precondition(failed.coordinator.display.removals == 1)

        func restores(_ value: AudioReconnectLease?, healthy: Bool = true, pid: Int32? = 123,
                      online: Bool = true, uptime: TimeInterval = 110, gone: TimeInterval? = 8) -> Bool {
            WatchdogRecoveryPolicy.shouldRestore(appHealthy: healthy, appPID: pid, uuGoneFor: gone,
                lease: value, heldDisplayOnline: online, uptime: uptime, disconnectLimit: 5)
        }
        precondition(!restores(lease))
        precondition(restores(lease, healthy: false))
        precondition(restores(lease, pid: 999) && restores(lease, pid: nil))
        precondition(restores(lease, online: false))
        precondition(restores(lease, uptime: 115) && restores(lease, uptime: 99))
        precondition(restores(nil) && !restores(nil, gone: 5) && !restores(nil, gone: nil))
        let oversized = AudioReconnectLease(version: 1, pid: 123, displayID: 1, startedAt: 100, deadline: 999)
        precondition(restores(oversized))
        let invalid = AudioReconnectLease(version: 99, pid: 123, displayID: 1, startedAt: 100, deadline: 115)
        precondition(restores(invalid))
        try Data("broken".utf8).write(to: root.appendingPathComponent("broken.json"))
        precondition(AudioReconnectLease.read(from: root.appendingPathComponent("broken.json")) == nil)
        print("PASS: audio reconnect preserves the same display, expires within 15 seconds, cancels on explicit actions, rejects invalid leases and never exempts watchdog heartbeat failures")
    }
}
