import Combine
import Foundation

/// 窗口保持打开；开始只启动恢复流程，关闭和停止是用户明确的独立操作。
final class AudioRecoveryGuideModel: ObservableObject {
    @Published var recovery = AudioRecoveryStatus()
    @Published var capture = AudioCaptureStatus()
    private let recoveryStatus: () -> AudioRecoveryStatus
    private let captureStatus: () -> AudioCaptureStatus
    private let onStart: () -> Void
    private let onStop: () -> Void
    private let onRefresh: () -> Void
    private var timer: Timer?

    init(recoveryStatus: @escaping () -> AudioRecoveryStatus, captureStatus: @escaping () -> AudioCaptureStatus,
         onStart: @escaping () -> Void, onStop: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.recoveryStatus = recoveryStatus
        self.captureStatus = captureStatus
        self.onStart = onStart
        self.onStop = onStop
        self.onRefresh = onRefresh
        refresh()
    }

    func startUpdating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    func stopUpdating() { timer?.invalidate(); timer = nil }
    func refresh() { recovery = recoveryStatus(); capture = captureStatus() }
    func startRecovery() {
        refresh()
        guard recovery.available else { return }
        onStart()
        refresh()
    }
    func stopRecovery() { onStop(); refresh() }
    func refreshCapture() { onRefresh(); refresh() }
    deinit { timer?.invalidate() }
}
