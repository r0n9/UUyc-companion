import Foundation

@main struct AudioCaptureTests {
    static func main() throws {
        func row(_ time: UInt64, _ message: String, pid: Int = 866, boot: String = "boot") -> [String: Any] {
            ["bootUUID": boot, "processID": pid, "machTimestamp": time,
             "processImagePath": "/Applications/UURemote.app/Contents/Helpers/UURemoteServer", "eventMessage": message]
        }
        func event(_ time: UInt64, _ message: String, pid: Int = 866, boot: String = "boot") -> AudioCaptureEvent {
            AudioCaptureEvent.decode(row(time, message, pid: pid, boot: boot))!
        }
        let audio = [
            event(1, "initWithFilter: (0xa) streamID=<private>"),
            event(2, "addStreamOutput: 0xa streamID=<private> type=1"),
            event(3, "startCaptureWithCompletionHandler: 0xa streamID=<private>")
        ]
        let video = [
            event(5, "initWithFilter: (0xb) streamID=<private>"),
            event(6, "addStreamOutput: 0xb streamID=<private> type=0"),
            event(7, "startCaptureWithCompletionHandler: 0xb streamID=<private>")
        ]
        var state = AudioCaptureState()
        precondition(state.kind == .unknown)
        state.consume(audio)
        precondition(state.kind == .detected)
        state.consume(video) // 独立音频流仍活着时，不能因为视频流没有音频而误报。
        precondition(state.kind == .detected)
        state.consume([event(8, "stopCaptureWithCompletionHandler: 0xa streamID=<private>")])
        precondition(state.kind == .suspected)
        state.consume(audio + video) // 重叠查询不能复活已经停止的旧流。
        precondition(state.kind == .suspected)
        state.consume([
            event(9, "initWithFilter: (0xa) streamID=<private>"),
            event(10, "addStreamOutput: 0xa streamID=<private> type=0"),
            event(11, "startCaptureWithCompletionHandler: 0xa streamID=<private>")
        ])
        precondition(state.kind == .suspected, "Reused stream pointer inherited old audio")
        state.consume([event(12, "addStreamOutput: 0xa streamID=<private> type=1")])
        precondition(state.kind == .detected)
        state.consume([event(13, "removeStreamOutput: 0xa streamID=<private> type=1")])
        precondition(state.kind == .suspected)
        state.consume([
            event(14, "addStreamOutput: 0xf streamID=<private> type=0", pid: 999),
            event(15, "startCaptureWithCompletionHandler: 0xf streamID=<private>", pid: 999)
        ])
        precondition(state.kind == .unknown, "Old process evidence leaked into new UU process")
        state.consume([
            event(1, "addStreamOutput: 0xc streamID=<private> type=1", pid: 999, boot: "new-boot"),
            event(2, "startCaptureWithCompletionHandler: 0xc streamID=<private>", pid: 999, boot: "new-boot")
        ])
        precondition(state.kind == .detected)

        let data = try audio.map {
            try JSONSerialization.data(withJSONObject: row($0.timestamp, [
                AudioCaptureEvent.Kind.created: "initWithFilter: (0xa) streamID=<private>",
                .audioAdded: "addStreamOutput: 0xa streamID=<private> type=1",
                .started: "startCaptureWithCompletionHandler: 0xa streamID=<private>"
            ][$0.kind]!))
        }.reduce(Data()) { $0 + $1 + Data([10]) }
        let decoded = try AudioCaptureLogReader.decode(data)
        precondition(decoded.count == 3)
        let progressData = Data("{\"count\":0,\"finished\":0}\n".utf8) + data + Data("{\"count\":3,\"finished\":1}\n".utf8)
        let progressEvents = try AudioCaptureLogReader.decode(progressData)
        precondition(progressEvents.count == 3)
        var removed = AudioCaptureState()
        removed.consume(audio + video)
        removed.consume([event(8, "removeStreamOutput: 0xb streamID=<private> type=0")])
        precondition(removed.kind == .detected)
        removed.consume([event(9, "removeStreamOutput: 0xa streamID=<private> type=1")])
        precondition(removed.kind == .unknown, "Removed video output should not count as a running video stream")
        precondition(AudioCaptureEvent.decode(row(20, "addStreamOutput: 0xa streamID=<private> type=10")) == nil)
        let hidden = try JSONSerialization.data(withJSONObject: row(20, "addStreamOutput: <private> streamID=<private> type=1"))
        do {
            _ = try AudioCaptureLogReader.decode(hidden)
            preconditionFailure("Redacted stream identity should not be classified")
        } catch AudioCaptureReadError.incomplete {}
        do {
            _ = try AudioCaptureLogReader.decode(Data("broken".utf8))
            preconditionFailure("Malformed log should not be classified")
        } catch {}

        // 查询在后台串行执行；断开后到达的旧结果不能污染新会话或堵住界面。
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads = 0
        let monitor = AudioCaptureMonitor(read: { _ in
            precondition(!Thread.isMainThread)
            lock.lock(); reads += 1; let current = reads; lock.unlock()
            if current == 1 { _ = gate.wait(timeout: .now() + 5); return audio }
            return video
        })
        monitor.onChange = { precondition(Thread.isMainThread) }
        monitor.updateContext(connected: true, displayID: 1, onlyVirtual: true)
        for _ in 0..<5 { monitor.refresh() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        lock.lock(); let firstReads = reads; lock.unlock()
        precondition(firstReads == 1)
        monitor.updateContext(connected: false, displayID: nil, onlyVirtual: false)
        gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(monitor.status.kind == .disconnected)
        monitor.updateContext(connected: true, displayID: 2, onlyVirtual: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(monitor.status.kind == .unknown)
        monitor.updateContext(connected: false, displayID: nil, onlyVirtual: false)

        let failure = AudioCaptureMonitor(read: { _ in throw AudioCaptureReadError.unavailable })
        failure.updateContext(connected: true, displayID: 3, onlyVirtual: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(failure.status.kind == .unknown && failure.status.detail != nil)
        failure.updateContext(connected: false, displayID: nil, onlyVirtual: false)
        print("PASS: audio capture lifecycle, dedicated audio, stopped/reused streams, overlapping logs, PID/boot resets, redaction, serial background reads and stale-result rejection")
    }
}
