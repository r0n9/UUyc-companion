import Foundation

struct AudioCaptureStatus: Equatable {
    enum Kind { case checking, detected, suspected, unknown, disconnected, physicalScreens }
    var kind: Kind = .unknown
    var checkedAt: Date?
    var refreshing = false
    var detail: String?

    var title: String {
        switch kind {
        case .checking: return "正在检测音频采集"
        case .detected: return "检测到音频采集流"
        case .suspected: return "疑似音频采集未恢复"
        case .unknown: return "暂时无法判断"
        case .disconnected: return "远程已断开，等待重新连接"
        case .physicalScreens: return "当前不是仅伴侣虚拟屏"
        }
    }

    var explanation: String {
        if let detail { return detail }
        switch kind {
        case .detected: return "发现 UU 的音频采集记录，但不能确认控制端已听到声音。请播放一段音频确认。"
        case .suspected: return "原音频流停止后只发现画面流。若控制端已开启「播放远程声音」，可尝试断开重连。"
        case .unknown: return "没有足够的采集记录。请在控制端开启「播放远程声音」，并播放一段音频确认。"
        case .checking: return "正在检查 UU 的音频采集状态，请稍候。"
        case .disconnected: return "重新连接后会再次检测；当前没有远程会话可供判断。"
        case .physicalScreens: return "仅虚拟屏远程时自动检测；音频采集状态不等同于控制端实际有声。"
        }
    }
}

struct AudioCaptureEvent {
    enum Kind { case created, audioAdded, videoAdded, audioRemoved, videoRemoved, started, stopped, failed }
    let boot: String
    let process: Int32
    let timestamp: UInt64
    let stream: String
    let kind: Kind

    static func decode(_ row: [String: Any]) -> AudioCaptureEvent? {
        guard let message = row["eventMessage"] as? String,
              let path = row["processImagePath"] as? String, path.hasSuffix("/UURemoteServer"),
              let boot = row["bootUUID"] as? String,
              let pid = row["processID"] as? NSNumber, pid.int32Value > 0,
              let stamp = row["machTimestamp"] as? NSNumber, stamp.int64Value > 0,
              let range = message.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) else { return nil }
        let kind: Kind
        if message.contains("initWithFilter:") { kind = .created }
        else if message.contains("addStreamOutput"), message.range(of: #"\btype=1\b"#, options: .regularExpression) != nil { kind = .audioAdded }
        else if message.contains("addStreamOutput"), message.range(of: #"\btype=0\b"#, options: .regularExpression) != nil { kind = .videoAdded }
        else if message.contains("removeStreamOutput"), message.range(of: #"\btype=1\b"#, options: .regularExpression) != nil { kind = .audioRemoved }
        else if message.contains("removeStreamOutput"), message.range(of: #"\btype=0\b"#, options: .regularExpression) != nil { kind = .videoRemoved }
        else if message.contains("startCaptureWithCompletionHandler"), message.contains("error=") { kind = .failed }
        else if message.contains("startCaptureWithCompletionHandler") { kind = .started }
        else if message.contains("stopCaptureWithCompletionHandler") { kind = .stopped }
        else { return nil }
        return AudioCaptureEvent(boot: boot, process: pid.int32Value, timestamp: stamp.uint64Value,
                                 stream: String(message[range]).lowercased(), kind: kind)
    }
}

/// 只推断采集流的生命周期，不把本机静音、没有音乐或私有 AudioTap 不可见当作故障。
struct AudioCaptureState {
    private struct Stream {
        var audio = false
        var video = false
        var running = false
        var stopped = false
    }
    private var boot: String?
    private var process: Int32?
    private var cursor: UInt64 = 0
    private var streams: [String: Stream] = [:]
    private var audioStopped = false

    mutating func consume(_ events: [AudioCaptureEvent]) {
        for event in events {
            if boot != event.boot || process != event.process {
                self = AudioCaptureState()
                boot = event.boot
                process = event.process
            }
            guard event.timestamp > cursor else { continue }
            cursor = event.timestamp
            var stream = streams[event.stream] ?? Stream()
            switch event.kind {
            case .created:
                stream = Stream()
            case .audioAdded, .videoAdded:
                if stream.stopped { stream = Stream() }
                if event.kind == .audioAdded { stream.audio = true } else { stream.video = true }
            case .started:
                stream.running = true
                stream.stopped = false
            case .stopped, .failed:
                if stream.audio && stream.running { audioStopped = true }
                stream.running = false
                stream.stopped = true
            case .audioRemoved:
                if stream.audio && stream.running { audioStopped = true }
                stream.audio = false
            case .videoRemoved:
                stream.video = false
            }
            streams[event.stream] = stream
            if streams.count > 256 { streams = streams.filter { $0.value.running || !$0.value.stopped } }
        }
    }

    var kind: AudioCaptureStatus.Kind {
        if streams.values.contains(where: { $0.running && $0.audio }) { return .detected }
        if audioStopped && streams.values.contains(where: { $0.running && $0.video && !$0.audio }) { return .suspected }
        return .unknown
    }
}
