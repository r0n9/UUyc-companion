import Foundation

enum AudioCaptureReadError: Error { case unavailable, timedOut, tooLarge, incomplete }

enum AudioCaptureLogReader {
    static func read(since: Date) throws -> [AudioCaptureEvent] {
        let limit = 1_048_576
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uudisplay-audio-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AudioCaptureReadError.unavailable }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "ndjson", "--info", "--start", formatter.string(from: since),
            "--predicate", """
            process == "UURemoteServer" AND (eventMessage CONTAINS "initWithFilter:" OR eventMessage CONTAINS "addStreamOutput" OR eventMessage CONTAINS "removeStreamOutput" OR eventMessage CONTAINS "startCaptureWithCompletionHandler" OR eventMessage CONTAINS "stopCaptureWithCompletionHandler")
            """]
        process.standardOutput = output
        process.standardError = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var failure: AudioCaptureReadError?
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > limit { failure = .tooLarge }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = .timedOut }
            if failure != nil {
                process.terminate()
                if done.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 1)
                }
                break
            }
        }
        if let failure { throw failure }
        guard process.terminationStatus == 0 else { throw AudioCaptureReadError.unavailable }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AudioCaptureReadError.tooLarge }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [AudioCaptureEvent] {
        var events: [AudioCaptureEvent] = []
        var finished: Int?
        for line in data.split(separator: 10) where !line.isEmpty {
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw AudioCaptureReadError.incomplete
            }
            if let value = row["finished"] as? Int {
                guard value == 0 || value == 1 else { throw AudioCaptureReadError.incomplete }
                finished = value
                continue
            }
            if let event = AudioCaptureEvent.decode(row) { events.append(event) }
            else if let message = row["eventMessage"] as? String, message.contains("streamID="),
                    message.range(of: #"\btype=[2-9][0-9]*\b|\btype=1[0-9]+\b"#, options: .regularExpression) == nil {
                // 有流记录但关键字段被隐藏，不能沿用之前的“检测到采集”结论。
                throw AudioCaptureReadError.incomplete
            }
        }
        if finished == 0 { throw AudioCaptureReadError.incomplete }
        return events
    }
}

/// 串行后台查询，单次四秒/1 MiB 上限；会话变化时拒绝旧查询，界面始终在主线程更新。
final class AudioCaptureMonitor {
    typealias Reader = (Date) throws -> [AudioCaptureEvent]
    private let read: Reader
    private let now: () -> Date
    private let queue = DispatchQueue(label: "uudisplay.audio-state", qos: .utility)
    private var timer: Timer?
    private var connected = false
    private var displayID: UInt32?
    private var onlyVirtual = false
    private var sessionStart: Date?
    private var lastRead: Date?
    private var generation = 0
    private var inFlight = false
    private var state = AudioCaptureState()
    private let createdAt: Date
    private(set) var status = AudioCaptureStatus(kind: .disconnected)
    var onChange: (() -> Void)?

    init(read: @escaping Reader = AudioCaptureLogReader.read, now: @escaping () -> Date = Date.init) {
        self.read = read
        self.now = now
        createdAt = now()
    }

    func updateContext(connected newConnected: Bool, displayID newDisplay: UInt32?, onlyVirtual newOnlyVirtual: Bool) {
        guard connected != newConnected || displayID != newDisplay || onlyVirtual != newOnlyVirtual else { return }
        if newConnected && !connected {
            // 启动时已存在的会话回看一小时；之后的新连接只保留五秒识别延迟余量。
            sessionStart = now().addingTimeInterval(now().timeIntervalSince(createdAt) < 5 ? -3600 : -5)
        }
        if !newConnected { sessionStart = nil }
        connected = newConnected
        displayID = newDisplay
        onlyVirtual = newOnlyVirtual
        generation += 1
        state = AudioCaptureState()
        lastRead = nil
        timer?.invalidate()
        timer = nil
        status = AudioCaptureStatus(kind: !connected ? .disconnected : (!onlyVirtual || displayID == nil ? .physicalScreens : .checking))
        onChange?()
        guard connected && onlyVirtual && displayID != nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func refresh() {
        guard connected, onlyVirtual, displayID != nil, !inFlight, let sessionStart else { return }
        inFlight = true
        status.refreshing = true
        onChange?()
        let token = generation
        let startedAt = now()
        let since = max(sessionStart, lastRead?.addingTimeInterval(-2) ?? sessionStart)
        let read = self.read
        queue.async { [weak self] in
            let result = Result { try read(since) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.generation == token else { self.refresh(); return }
                switch result {
                case .success(let events):
                    self.state.consume(events)
                    self.lastRead = startedAt
                    self.status = AudioCaptureStatus(kind: self.state.kind, checkedAt: self.now())
                case .failure:
                    self.state = AudioCaptureState()
                    self.lastRead = nil
                    self.status = AudioCaptureStatus(kind: .unknown, checkedAt: self.now(),
                        detail: "暂时无法读取完整的 UU 音频采集记录。请在控制端开启「播放远程声音」，播放音频确认。")
                }
                self.onChange?()
            }
        }
    }

    deinit { timer?.invalidate() }
}
