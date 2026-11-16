// 「关于」窗口：fork 版本、当前维护者、原作者、开源致谢与 Debug 编号开关
import AppKit
import SwiftUI

private struct ExternalLink: Identifiable {
    let title: String
    let url: String
    let icon: LinkIcon
    var id: String { url }
}

private enum LinkIcon {
    case symbol(String)
    case text(String, Color)
}

private struct OpenSource: Identifiable {
    let name: String
    let author: String
    let license: String
    let usage: String
    let url: String
    var id: String { url }
}

private enum AboutInfo {
    static let repository = "https://github.com/r0n9/UUyc-companion"
    static let maintainer: [ExternalLink] = [
        ExternalLink(title: "GitHub 主页", url: "https://github.com/r0n9",
                     icon: .symbol("person.crop.circle")),
        ExternalLink(title: "反馈问题", url: repository + "/issues", icon: .symbol("bubble.left")),
    ]

    static let originalAuthor: [ExternalLink] = [
        ExternalLink(title: "原作者主页", url: "https://ryou.im", icon: .symbol("globe")),
        ExternalLink(title: "X 主页", url: "https://x.com/corndogjpn2", icon: .text("𝕏", .primary)),
        ExternalLink(title: "小红书", url: "https://xhslink.cn/o/2M9LOaUzn01", icon: .text("书", .red)),
        ExternalLink(title: "GitHub 主页", url: "https://github.com/aoyamashou",
                     icon: .symbol("chevron.left.forwardslash.chevron.right")),
        ExternalLink(title: "上游仓库", url: "https://github.com/aoyamashou/UUyc-companion",
                     icon: .symbol("arrow.triangle.branch")),
    ]

    static let openSource: [OpenSource] = [
        OpenSource(name: "FreeDisplay", author: "huberdf", license: "MIT", usage: "虚拟屏接口声明",
                   url: "https://github.com/huberdf/FreeDisplay"),
        OpenSource(name: "PermissionFlow", author: "小弟调调（jaywcjlove）", license: "MIT", usage: "授权引导",
                   url: "https://github.com/jaywcjlove/PermissionFlow"),
        OpenSource(name: "TourKit", author: "Ram Patra（rampatra）", license: "MIT", usage: "功能介绍页",
                   url: "https://github.com/rampatra/TourKit"),
    ]

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

/// Debug 编号开关的界面状态（@State 在仅有 Command Line Tools 时不可用）
private final class AboutModel: ObservableObject {
    @Published var debugOn = DebugLabels.enabled
    func toggleDebug() {
        DebugLabels.enabled.toggle()
        debugOn = DebugLabels.enabled
    }
}

private struct LinkIconView: View {
    let icon: LinkIcon
    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 12, weight: .semibold))
        case .text(let s, let color):
            Text(s).font(.system(size: 13, weight: .heavy)).foregroundStyle(color)
        }
    }
}

private struct AboutView: View {
    @ObservedObject var model: AboutModel
    private let version = Bundle.main.infoDictionary?["UUDisplayReleaseVersion"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版（r0n9）"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("UU远程伴侣").font(.title2.bold())
                    Text("版本 \(version)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("项目仓库") { AboutInfo.open(AboutInfo.repository) }
            }
            Text("由 r0n9 基于 AoyamaShou 的原项目维护，自动匹配远程设备分辨率，改善 Mac 版 UU远程 的显示体验。")
                .fixedSize(horizontal: false, vertical: true)

            section("当前维护者") {
                HStack(spacing: 8) {
                    Text("r0n9").font(.body.bold())
                    ForEach(AboutInfo.maintainer) { link in
                        Button { AboutInfo.open(link.url) } label: {
                            HStack(spacing: 5) {
                                LinkIconView(icon: link.icon).frame(width: 16)
                                Text(link.title)
                            }
                        }
                        .help(link.url)
                    }
                }
                Text("此维护版优化反复连接与分辨率调整时的稳定性。")
                    .foregroundStyle(.secondary)
            }

            section("原作者") {
                Text("AoyamaShou").font(.body.bold())
                HStack(spacing: 8) {
                    ForEach(AboutInfo.originalAuthor) { link in
                        Button { AboutInfo.open(link.url) } label: {
                            HStack(spacing: 5) {
                                LinkIconView(icon: link.icon).frame(width: 16)
                                Text(link.title)
                            }
                        }
                        .help(link.url)
                    }
                }
            }

            section("致谢开源项目") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AboutInfo.openSource) { p in
                        HStack(spacing: 6) {
                            Button { AboutInfo.open(p.url) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10, weight: .semibold))
                                    Text(p.name).underline()
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help(p.url)
                            Text("作者 \(p.author) · \(p.license) 协议 · \(p.usage)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            section("声明") {
                Text("本项目是 UUyc companion 的独立维护分支，与 UU远程 及其开发商没有关联。本应用仅用于改善远程显示体验；如果 UU远程 官方内置了同样的功能，可直接卸载本应用。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(model.debugOn ? "Debug：隐藏编号" : "Debug：显示编号") { model.toggleDebug() }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView(model: AboutModel()))
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "关于 UU远程伴侣"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染为 PNG（--render-about <文件>）
    static func render(to url: URL) {
        let view = NSHostingView(rootView: AboutView(model: AboutModel()))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// 保留应用入口使用的接口，窗口与调试编号均由本仓库实现。
enum AboutPage {
    static func show() { AboutWindowController.shared.show() }
    static func render(to url: URL) { AboutWindowController.render(to: url) }
    static func setUpDebugLabels() { DebugLabels.start() }
}
