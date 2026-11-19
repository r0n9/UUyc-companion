import Combine
import Foundation

/// 窗口保持打开；开始只启动恢复流程，关闭和停止是用户明确的独立操作。
final class AudioRecoveryGuideModel: ObservableObject {
    enum TestSoundState { case idle, playing, finished, stopped, failed }
    @Published var recovery = AudioRecoveryStatus()
    @Published var capture = AudioCaptureStatus()
    @Published var testSoundState: TestSoundState = .idle
    @Published var testSoundRemainingSeconds = 0
    private let recoveryStatus: () -> AudioRecoveryStatus
    private let captureStatus: () -> AudioCaptureStatus
    private let onStart: () -> Void
    private let onStop: () -> Void
    private let onRefresh: () -> Void
    private let testSoundPlayer: AudioTestSoundPlaying
    private let uptime: () -> TimeInterval
    private var testSoundDeadline: TimeInterval?
    private var playbackGeneration = 0
    private var timer: Timer?

    init(recoveryStatus: @escaping () -> AudioRecoveryStatus, captureStatus: @escaping () -> AudioCaptureStatus,
         onStart: @escaping () -> Void, onStop: @escaping () -> Void, onRefresh: @escaping () -> Void,
         testSoundPlayer: AudioTestSoundPlaying = AudioTestSoundPlayer(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.recoveryStatus = recoveryStatus
        self.captureStatus = captureStatus
        self.onStart = onStart
        self.onStop = onStop
        self.onRefresh = onRefresh
        self.testSoundPlayer = testSoundPlayer
        self.uptime = uptime
        refresh()
    }

    func startUpdating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    func stopUpdating() { timer?.invalidate(); timer = nil; stopTestSound() }
    func refresh() {
        recovery = recoveryStatus()
        capture = captureStatus()
        if !canPlayTestSound { stopTestSound() }
        if let testSoundDeadline {
            testSoundRemainingSeconds = max(0, Int(ceil(testSoundDeadline - uptime())))
        }
    }
    var canPlayTestSound: Bool { capture.kind != .disconnected && recovery.remainingSeconds == 0 }
    var testSoundMessage: String {
        switch testSoundState {
        case .idle: return "点击后播放约 4 秒提示音，请在控制设备上确认是否听到。"
        case .playing: return "正在播放 · 剩余 \(testSoundRemainingSeconds) 秒，请在控制设备上试听。"
        case .finished: return "播放已结束。如果控制设备听到了提示音，远程声音可用。"
        case .stopped: return "测试声音已停止，可在连接后再次播放。"
        case .failed: return "测试声音播放失败，请重试。"
        }
    }
    func playTestSound() {
        refresh()
        guard canPlayTestSound, testSoundState != .playing else { return }
        playbackGeneration += 1
        let generation = playbackGeneration
        testSoundPlayer.onFinish = { [weak self] success in
            guard let self, self.playbackGeneration == generation else { return }
            self.playbackGeneration += 1
            self.testSoundPlayer.onFinish = nil
            self.testSoundDeadline = nil
            self.testSoundRemainingSeconds = 0
            self.testSoundState = success ? .finished : .failed
        }
        testSoundState = .playing
        testSoundDeadline = uptime() + AudioTestTone.duration
        testSoundRemainingSeconds = Int(AudioTestTone.duration)
        do { try testSoundPlayer.play() }
        catch {
            stopTestSound()
            testSoundState = .failed
        }
    }
    func stopTestSound() {
        guard testSoundState == .playing else { return }
        playbackGeneration += 1
        testSoundPlayer.onFinish = nil
        testSoundPlayer.stop()
        testSoundDeadline = nil
        testSoundRemainingSeconds = 0
        testSoundState = .stopped
    }
    func startRecovery() {
        refresh()
        guard recovery.available else { return }
        stopTestSound()
        onStart()
        refresh()
    }
    func stopRecovery() { onStop(); refresh() }
    func refreshCapture() { onRefresh(); refresh() }
    deinit { timer?.invalidate(); testSoundPlayer.onFinish = nil; testSoundPlayer.stop() }
}
