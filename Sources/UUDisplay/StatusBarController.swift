// 菜单栏：连接摘要 / 远程时只保留虚拟屏 / 远程音频 / 设置 / 完全退出
import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPane?) -> Void
    private let store = ConfigStore.shared
    private var connectionStatusItem: NSMenuItem?
    private var connectionStatusView: MenuConnectionStatusView?
    private var audioStatusItem: NSMenuItem?
    private var connectionDebugPrefix = ""
    private var audioDebugPrefix = ""

    init(coordinator: Coordinator, openSettings: @escaping (SettingsPane?) -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 320
        item.menu = menu
        refresh()
    }

    /// 菜单栏图标：Assets/AppIcon/MenuBarIconTemplate（模板图，深色菜单栏自动反白）；
    /// 非 .app 运行（调试）找不到资源时退回系统图标
    private static let menuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    func refresh() {
        let icon = StatusBarController.menuBarIcon
        icon.accessibilityDescription = "UU远程伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused  // 暂停自动切换时图标变灰
        item.button?.toolTip = "UU远程伴侣：\(coordinator.statusText)"
        updateConnectionStatus()
        updateAudioStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        connectionDebugPrefix = ""
        audioDebugPrefix = ""
        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        let statusView = MenuConnectionStatusView()
        status.view = statusView
        connectionStatusItem = status
        connectionStatusView = statusView
        audioStatusItem = nil
        menu.addItem(status)
        menu.addItem(.separator())

        let physical = action("远程时只保留虚拟屏", #selector(toggleDisablePhysical), symbol: "display.2")
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        menu.addItem(physical)
        if store.config.shouldDisablePhysical {
            menu.addItem(.separator())
            let audioStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            audioStatus.isEnabled = false
            audioStatusItem = audioStatus
            menu.addItem(audioStatus)
            let audio = action("恢复远程声音…", #selector(recoverAudio), symbol: "arrow.triangle.2.circlepath")
            audio.toolTip = "查看当前音频采集状态与恢复步骤。开始后窗口保持打开并更新进度。"
            menu.addItem(audio)
        }
        menu.addItem(.separator())
        menu.addItem(action("设置…", #selector(reconfigure), symbol: "gearshape", key: ","))
        menu.addItem(action("完全退出", #selector(quit), symbol: "power", key: "q"))
        refresh()
        DebugLabels.decorate(menu)
        if DebugLabels.enabled {
            connectionDebugPrefix = (status.title.components(separatedBy: " ").first ?? "") + " "
            if let audioStatusItem {
                audioDebugPrefix = (audioStatusItem.title.components(separatedBy: " ").first ?? "") + " "
            }
        }
        // 自定义状态摘要也显示调试编号，和菜单项编号保持一致。
        updateConnectionStatus()
        updateAudioStatus()
    }

    private func updateConnectionStatus() {
        guard let status = connectionStatusItem, let view = connectionStatusView else { return }
        let text = coordinator.statusText
        status.title = connectionDebugPrefix + text
        status.toolTip = text
        let warning = text.hasPrefix("⚠️")
        let recovering = coordinator.audioRecoveryStatus.remainingSeconds > 0
        let symbol = warning ? "exclamationmark.triangle" : recovering ? "arrow.triangle.2.circlepath"
            : store.config.paused ? "pause" : "display"
        let color: NSColor = warning ? .systemOrange : recovering ? .systemBlue
            : store.config.paused || !coordinator.connected ? .secondaryLabelColor : .systemGreen
        let detail = warning ? "请查看当前状态与操作提示。" : store.config.paused ? "连接时暂不调整屏幕。"
            : "连接后自动匹配设备的虚拟屏配置。"
        view.update(statusText: status.title, fallbackDetail: detail, symbol: symbol, color: color)
    }

    private func updateAudioStatus() {
        guard let audioStatusItem else { return }
        let status = coordinator.audioCaptureStatus
        let title = "\(audioDebugPrefix)远程音频：\(status.title)"
        audioStatusItem.title = title
        audioStatusItem.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        setMenuIcon(status.kind == .suspected ? "exclamationmark.triangle" : "waveform", on: audioStatusItem)
        audioStatusItem.toolTip = status.explanation
    }

    private func menuIcon(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func setMenuIcon(_ symbol: String, on menuItem: NSMenuItem) {
        menuItem.image = menuIcon(symbol)
        // macOS 27 默认隐藏菜单图标；动态设置公开属性，兼容较早版本的 SDK。
        if menuItem.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            menuItem.setValue(1, forKey: "preferredImageVisibility") // .visible
        }
    }

    private func action(_ title: String, _ sel: Selector, symbol: String, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        setMenuIcon(symbol, on: it)
        return it
    }

    @objc private func reconfigure() { openSettings(nil) }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }
    @objc private func recoverAudio() { coordinator.requestAudioRecovery() }

    /// 与设置窗口的「完全退出」一致：停掉本次登录中的守护助手，再退出主程序
    @objc private func quit() {
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}

/// 菜单顶部只展示状态；下方操作继续使用原生菜单项和键盘导航。
private final class MenuConnectionStatusView: NSView {
    private let icon = MenuStatusIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        icon.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        detailLabel.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(statusText: String, fallbackDetail: String, symbol: String, color: NSColor) {
        let parts = statusText.components(separatedBy: " · ")
        titleLabel.stringValue = parts.first ?? statusText
        detailLabel.stringValue = parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : fallbackDetail
        icon.update(symbol: symbol, color: color)
        toolTip = statusText
        setAccessibilityLabel(statusText)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textWidth = bounds.width - 78
        icon.frame = NSRect(x: 18, y: 24, width: 32, height: 32)
        titleLabel.frame = NSRect(x: 62, y: 13, width: textWidth, height: 20)
        detailLabel.frame = NSRect(x: 62, y: 36, width: textWidth, height: 32)
    }
}

private final class MenuStatusIconView: NSView {
    private let imageView = NSImageView()
    private var color = NSColor.secondaryLabelColor

    init() {
        super.init(frame: .zero)
        addSubview(imageView)
        imageView.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(symbol: String, color: NSColor) {
        self.color = color
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        imageView.contentTintColor = color
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
