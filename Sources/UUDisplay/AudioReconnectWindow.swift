// 用户主动恢复远程声音时，短暂保留同一显示器；主程序与守护助手共用固定截止时间。
import Foundation

struct AudioReconnectLease: Codable, Equatable {
    static let duration: TimeInterval = 15
    let version: Int
    let pid: Int32
    let displayID: UInt32
    let startedAt: TimeInterval
    let deadline: TimeInterval

    func isValid(at uptime: TimeInterval, appPID: Int32) -> Bool {
        version == 1 && pid > 0 && pid == appPID && displayID != 0
            && uptime.isFinite && startedAt.isFinite && deadline.isFinite
            && deadline > startedAt && deadline - startedAt <= Self.duration
            && uptime >= startedAt && uptime < deadline
    }

    static func read(from url: URL) -> AudioReconnectLease? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct AudioRecoveryStatus {
    enum Outcome { case reconnected, expired, finishedWaiting, cancelled }
    var available = false
    var remainingSeconds = 0
    var waitingForReconnect = false
    var confirmingReconnect = false
    var error: String?
    var notice: String?
    var outcome: Outcome?

    var activeStep: Int? {
        if remainingSeconds > 0 { return waitingForReconnect || confirmingReconnect ? 1 : 0 }
        if outcome == .reconnected { return 2 }
        return nil
    }

    var instruction: String? {
        guard remainingSeconds > 0 else { return notice }
        if confirmingReconnect { return "正在确认重新连接的设备，请稍候。" }
        return waitingForReconnect
            ? "第 2 步：回到控制设备的 UU远程列表，重新连接同一台 Mac。"
            : "第 1 步：现在到你手上的设备，在 UU远程中断开当前连接。"
    }
}

final class AudioReconnectWindow {
    static let markerURL = ConfigStore.dir.appendingPathComponent("audio-reconnect.json")
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    private let url: URL
    private let pid: Int32
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private var generation = 0
    private(set) var lease: AudioReconnectLease?
    private(set) var waitingForReconnect = false
    var onExpire: ((_ wasDisconnected: Bool) -> Void)?

    init(url: URL = AudioReconnectWindow.markerURL, pid: Int32 = getpid(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Scheduler = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.url = url
        self.pid = pid
        self.now = now
        self.schedule = schedule
    }

    var isArmed: Bool { lease != nil }
    var remainingSeconds: Int {
        let uptime = now()
        guard let lease, lease.isValid(at: uptime, appPID: pid) else { return 0 }
        return Int(ceil(lease.deadline - uptime))
    }

    /// 不允许反复点击续期；落盘失败时不改变正常断开行为。
    func begin(displayID: UInt32) -> Bool {
        guard lease == nil, displayID != 0 else { return false }
        if let stored = AudioReconnectLease.read(from: url), stored.isValid(at: now(), appPID: stored.pid) {
            return false
        }
        let uptime = now()
        let value = AudioReconnectLease(version: 1, pid: pid, displayID: displayID,
                                        startedAt: uptime, deadline: uptime + AudioReconnectLease.duration)
        guard value.isValid(at: uptime, appPID: pid),
              (try? JSONEncoder().encode(value).write(to: url, options: .atomic)) != nil else { return false }
        lease = value
        waitingForReconnect = false
        generation += 1
        scheduleExpiry(generation: generation)
        return true
    }

    func holdOnDisconnect(displayID: UInt32?) -> Bool {
        guard let lease, lease.displayID == displayID, lease.isValid(at: now(), appPID: pid) else {
            cancel()
            return false
        }
        waitingForReconnect = true
        return true
    }

    func completeReconnect(displayID: UInt32?) -> Bool {
        guard waitingForReconnect, let lease, lease.displayID == displayID,
              lease.isValid(at: now(), appPID: pid) else { return false }
        cancel()
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        let wasDisconnected = waitingForReconnect
        if let lease, AudioReconnectLease.read(from: url) == lease {
            try? FileManager.default.removeItem(at: url)
        }
        lease = nil
        waitingForReconnect = false
        generation += 1
        return wasDisconnected
    }

    private func scheduleExpiry(generation token: Int) {
        guard let lease else { return }
        schedule(max(0, lease.deadline - now())) { [weak self] in
            guard let self, self.generation == token, let lease = self.lease else { return }
            if lease.isValid(at: self.now(), appPID: self.pid) {
                return self.scheduleExpiry(generation: token)
            }
            let wasDisconnected = self.cancel()
            self.onExpire?(wasDisconnected)
        }
    }
}
