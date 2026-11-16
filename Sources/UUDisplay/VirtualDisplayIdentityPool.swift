// 固定身份槽位：先持久化再使用；对象撤销后须确认显示器离线，才允许复用。
import Foundation

final class VirtualDisplayIdentityPool {
    static let vendorID: UInt32 = 0x5555
    static let productID: UInt32 = 0x0001
    static let serials: [UInt32] = [0x5555_0001, 0x5555_0002]

    private struct Registry: Codable {
        let version: Int
        let serials: [UInt32]
    }

    enum RegistryError: Error { case incompatibleRegistry }

    private var reserved: Set<UInt32> = []
    private var awaitingRemoval: [UInt32: UInt32] = [:]
    var hasPendingRemoval: Bool { !awaitingRemoval.isEmpty }

    init(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url))
            guard registry.version == 1, registry.serials == Self.serials else {
                throw RegistryError.incompatibleRegistry
            }
        } else {
            // 文件丢失时仍恢复同一组常量，不能生成另一批身份。
            let registry = Registry(version: 1, serials: Self.serials)
            try JSONEncoder().encode(registry).write(to: url, options: .atomic)
        }
    }

    func reserve(occupiedSerials: Set<UInt32>) -> UInt32? {
        guard let serial = Self.serials.first(where: {
            !reserved.contains($0) && awaitingRemoval[$0] == nil && !occupiedSerials.contains($0)
        }) else { return nil }
        reserved.insert(serial)
        return serial
    }

    /// 构造器返回 nil 时没有创建显示器，可以立即退回预留槽位。
    func cancelReservation(_ serial: UInt32) {
        reserved.remove(serial)
    }

    /// 仅移除对象引用不代表系统已撤销显示器，继续占用槽位。
    func awaitRemoval(serial: UInt32, displayID: UInt32) {
        reserved.remove(serial)
        awaitingRemoval[serial] = displayID
    }

    func reconcile(onlineDisplayIDs: Set<UInt32>) {
        awaitingRemoval = awaitingRemoval.filter { onlineDisplayIDs.contains($0.value) }
    }
}
