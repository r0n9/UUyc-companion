import Foundation

enum WatchdogRecoveryPolicy {
    static func shouldRestore(appHealthy: Bool, appPID: Int32?, uuGoneFor: TimeInterval?,
                              lease: AudioReconnectLease?, heldDisplayOnline: Bool,
                              uptime: TimeInterval, disconnectLimit: TimeInterval) -> Bool {
        // 退出或心跳超时始终优先，不能被重连窗口豁免。
        guard appHealthy else { return true }
        guard let uuGoneFor, uuGoneFor > disconnectLimit else { return false }
        if let lease, let appPID, heldDisplayOnline, lease.isValid(at: uptime, appPID: appPID) { return false }
        return true
    }
}
