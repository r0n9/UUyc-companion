import Foundation

@main struct IdentityTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identities.json")
        let pool = try VirtualDisplayIdentityPool(url: url)
        let serials = VirtualDisplayIdentityPool.serials
        let first = pool.reserve(occupiedSerials: [])!
        let second = pool.reserve(occupiedSerials: [])!
        precondition(first != second && pool.reserve(occupiedSerials: []) == nil)
        pool.awaitRemoval(serial: first, displayID: 100)
        pool.reconcile(onlineDisplayIDs: [100])
        precondition(pool.hasPendingRemoval && pool.reserve(occupiedSerials: []) == nil)
        pool.reconcile(onlineDisplayIDs: [])
        precondition(!pool.hasPendingRemoval && pool.reserve(occupiedSerials: []) == first)
        pool.cancelReservation(first)
        pool.cancelReservation(second)
        precondition(pool.reserve(occupiedSerials: Set(serials)) == nil)

        var used = Set<UInt32>()
        for round in 0..<1000 {
            let primary = pool.reserve(occupiedSerials: [])!
            let replacement = pool.reserve(occupiedSerials: [primary])!
            used.formUnion([primary, replacement])
            pool.awaitRemoval(serial: primary, displayID: UInt32(round * 2 + 100))
            precondition(pool.reserve(occupiedSerials: []) == nil)
            pool.reconcile(onlineDisplayIDs: [])
            pool.awaitRemoval(serial: replacement, displayID: UInt32(round * 2 + 101))
            pool.reconcile(onlineDisplayIDs: [])
        }
        precondition(used == Set(serials))
        let reopened = try VirtualDisplayIdentityPool(url: url)
        precondition(reopened.reserve(occupiedSerials: []) == first)
        try FileManager.default.removeItem(at: url)
        let recreated = try VirtualDisplayIdentityPool(url: url)
        precondition(recreated.reserve(occupiedSerials: []) == first)

        for invalid in ["broken", "{\"version\":2,\"serials\":[1,2]}", "{\"version\":1,\"serials\":[1,1]}"] {
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            do {
                _ = try VirtualDisplayIdentityPool(url: url)
                preconditionFailure("Corrupt or incompatible identities must not silently rotate")
            } catch {}
            let preserved = try String(contentsOf: url, encoding: .utf8)
            precondition(preserved == invalid)
        }
        do {
            _ = try VirtualDisplayIdentityPool(url: directory.appendingPathComponent("missing/identities.json"))
            preconditionFailure("Failed persistence must stop allocation")
        } catch {}
        print("PASS: 1000 reconnect/rebuild cycles use two persistent identities; occupied, retiring, corrupt and unwritable slots stay protected")
    }
}
