import AppKit
import SwiftUI

struct AudioRecoveryStepsView: View {
    var introduction = "先读完下面的步骤，点击「开始 15 秒重连」后再操作。"
    var activeStep: Int?
    private let steps = [
        "在你手上的手机、平板或电脑的 UU远程中，断开当前与这台 Mac 的连接。",
        "等远程画面关闭后，回到 UU远程的设备列表，在 15 秒内重新连接同一台 Mac。",
        "重新连接后播放一段音频，确认远程声音是否恢复。",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(introduction)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").fontWeight(.semibold).monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(activeStep == index ? Color.accentColor : Color.primary)
            }
            Text("计时期间会暂时保留当前虚拟屏；断开后超时未完成重连，会恢复物理屏。关闭此窗口会结束等待。UU 的「被控端静音」可保持开启。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AudioCaptureStatusView: View {
    let status: AudioCaptureStatus
    var onRefresh: () -> Void

    private var color: Color {
        switch status.kind {
        case .suspected: return .orange
        case .detected: return .blue
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(status.title, systemImage: status.kind == .suspected ? "exclamationmark.triangle" : "waveform")
                    .font(.headline).foregroundStyle(color)
                Spacer()
                if status.refreshing || status.kind == .checking { ProgressView().controlSize(.small) }
                Button("刷新检测", action: onRefresh)
                    .disabled(status.refreshing || status.kind == .checking || status.kind == .disconnected || status.kind == .physicalScreens)
            }
            Text(status.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let date = status.checkedAt {
                Text("最近检测：\(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

private struct AudioRecoveryGuideView: View {
    @ObservedObject var model: AudioRecoveryGuideModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("通过断开重连恢复远程声音", systemImage: "speaker.wave.2")
                .font(.title3.bold())
            Text("需要你手动断开并重新连接。开始后窗口会保持打开，实时显示当前步骤和采集状态。")
                .font(.callout).foregroundStyle(.secondary)
            AudioCaptureStatusView(status: model.capture, onRefresh: { model.refreshCapture() })
            if model.recovery.remainingSeconds > 0 {
                HStack {
                    Text("剩余 \(model.recovery.remainingSeconds) 秒").font(.title3.bold()).monospacedDigit()
                    Spacer()
                    Text("屏幕保留中").foregroundStyle(.secondary)
                }
                ProgressView(value: Double(model.recovery.remainingSeconds), total: AudioReconnectLease.duration)
            }
            if let instruction = model.recovery.instruction {
                Text(instruction).font(.headline).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.recovery.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            AudioRecoveryStepsView(
                introduction: model.recovery.remainingSeconds > 0 ? "请按当前高亮步骤操作。" :
                    (model.recovery.outcome == .reconnected ? "重连已完成，请先确认声音；仍无声时可再次尝试。" : "阅读说明不计时；准备好后再开始。"),
                activeStep: model.recovery.activeStep)
            Divider()
            HStack {
                Button(model.recovery.remainingSeconds > 0 ? "停止本次恢复" : "关闭") {
                    if model.recovery.remainingSeconds > 0 { model.stopRecovery() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.recovery.remainingSeconds > 0 ? "重连进行中" :
                    (model.recovery.outcome == nil ? "开始 15 秒重连" : "再次尝试（15 秒）")) { model.startRecovery() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.recovery.available)
            }
            .controlSize(.large)
            if !model.recovery.available && model.recovery.remainingSeconds == 0 && model.recovery.notice == nil {
                Text("远程已连接、虚拟屏就绪且物理屏已关闭时，才能开始重连恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

final class AudioRecoveryGuide: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AudioRecoveryGuideModel?

    func show(recoveryStatus: @escaping () -> AudioRecoveryStatus, captureStatus: @escaping () -> AudioCaptureStatus,
              onStart: @escaping () -> Void, onStop: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        if let window {
            model?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = AudioRecoveryGuideModel(recoveryStatus: recoveryStatus, captureStatus: captureStatus,
                                            onStart: onStart, onStop: onStop, onRefresh: onRefresh)
        self.model = model
        let hosting = NSHostingController(rootView: AudioRecoveryGuideView(model: model, onClose: { [weak self] in self?.window?.close() }))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "恢复远程声音"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        self.window = window
        model.startUpdating()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() { model?.refresh() }
    func windowWillClose(_ notification: Notification) {
        model?.stopUpdating()
        model?.stopRecovery()
        model = nil
        window = nil
    }

    /// 只渲染操作指引，不启动计时或改变连接。
    static func render(to url: URL) {
        render(to: url, recovery: AudioRecoveryStatus(available: true), capture: AudioCaptureStatus(kind: .suspected))
        let parent = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        render(to: parent.appendingPathComponent("\(base)-disconnect.png"),
               recovery: AudioRecoveryStatus(remainingSeconds: 15), capture: AudioCaptureStatus(kind: .suspected))
        render(to: parent.appendingPathComponent("\(base)-reconnect.png"),
               recovery: AudioRecoveryStatus(remainingSeconds: 9, waitingForReconnect: true),
               capture: AudioCaptureStatus(kind: .disconnected))
        render(to: parent.appendingPathComponent("\(base)-completed.png"),
               recovery: AudioRecoveryStatus(available: true, notice: "已重新连接，请播放音频确认远程声音。", outcome: .reconnected),
               capture: AudioCaptureStatus(kind: .detected))
    }

    private static func render(to url: URL, recovery: AudioRecoveryStatus, capture: AudioCaptureStatus) {
        let model = AudioRecoveryGuideModel(recoveryStatus: { recovery }, captureStatus: { capture },
                                            onStart: {}, onStop: {}, onRefresh: {})
        let view = NSHostingView(rootView: AudioRecoveryGuideView(model: model, onClose: {})
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
