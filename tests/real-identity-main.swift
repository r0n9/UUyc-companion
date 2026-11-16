import CGVirtualDisplayBridge
import ColorSync
import CoreGraphics
import Foundation

func online() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    precondition(CGGetOnlineDisplayList(0, nil, &count) == .success)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    precondition(CGGetOnlineDisplayList(count, &ids, &count) == .success)
    return Array(ids.prefix(Int(count)))
}

@main struct RealIdentityTests {
    static func main() throws {
        let originalMain = CGMainDisplayID()
        precondition(online().contains { CGDisplayVendorNumber($0) != VirtualDisplayIdentityPool.vendorID })
        precondition(!online().contains { CGDisplayVendorNumber($0) == VirtualDisplayIdentityPool.vendorID }, "Exit the app and probe tools first")
        let pool = try VirtualDisplayIdentityPool(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        var observed: [UInt32: String] = [:]
        func create(width: Int, height: Int, hiDPI: Bool) -> (CGVirtualDisplay, UInt32) {
            let occupied = Set(online().filter { CGDisplayVendorNumber($0) == VirtualDisplayIdentityPool.vendorID }.map { CGDisplaySerialNumber($0) })
            let serial = pool.reserve(occupiedSerials: occupied)!
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.name = "UUyc companion"
            descriptor.maxPixelsWide = UInt32(width)
            descriptor.maxPixelsHigh = UInt32(height)
            descriptor.sizeInMillimeters = CGSize(width: Double(width) / 220 * 25.4, height: Double(height) / 220 * 25.4)
            descriptor.vendorID = VirtualDisplayIdentityPool.vendorID
            descriptor.productID = VirtualDisplayIdentityPool.productID
            descriptor.serialNum = serial
            let display: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: descriptor) }
            guard let display else { preconditionFailure("Constructor failed") }
            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = hiDPI
            settings.modes = [CGVirtualDisplayMode(width: UInt(hiDPI ? width / 2 : width), height: UInt(hiDPI ? height / 2 : height), refreshRate: 60)!]
            let applied = display.apply(settings)
            // 即使 API 失败也先等待，避免过早释放虚拟屏。
            RunLoop.main.run(until: Date().addingTimeInterval(applied ? 3 : 9))
            precondition(applied && online().contains(display.displayID))
            let identifier = CGDisplayCreateUUIDFromDisplayID(display.displayID)!.takeRetainedValue()
            let text = CFUUIDCreateString(nil, identifier)! as String
            if let existing = observed[serial] { precondition(existing == text, "A stable serial changed UUID") }
            observed[serial] = text
            precondition(CGMainDisplayID() == originalMain, "Main display unexpectedly changed")
            print("ONLINE serial=\(serial) UUID=\(text) size=\(width)x\(height) hiDPI=\(hiDPI)")
            return (display, serial)
        }
        func release(_ display: inout CGVirtualDisplay?, serial: UInt32) {
            let id = display!.displayID
            pool.awaitRemoval(serial: serial, displayID: id)
            autoreleasepool { display = nil }
            let deadline = Date().addingTimeInterval(10)
            while online().contains(id), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            }
            precondition(!online().contains(id), "Released display stayed online")
            pool.reconcile(onlineDisplayIDs: Set(online()))
        }
        for round in 0..<2 {
            var one: (CGVirtualDisplay, UInt32)? = create(width: round == 0 ? 2360 : 3024, height: round == 0 ? 1640 : 1964, hiDPI: round == 0)
            var first: CGVirtualDisplay? = one!.0
            let firstSerial = one!.1
            one = nil
            var two: (CGVirtualDisplay, UInt32)? = create(width: round == 0 ? 2400 : 2360, height: round == 0 ? 1080 : 1640, hiDPI: true)
            var second: CGVirtualDisplay? = two!.0
            let secondSerial = two!.1
            two = nil
            release(&first, serial: firstSerial)
            release(&second, serial: secondSerial)
        }
        precondition(observed.count == 2 && !pool.hasPendingRemoval)
        precondition(!online().contains { CGDisplayVendorNumber($0) == VirtualDisplayIdentityPool.vendorID })
        precondition(CGMainDisplayID() == originalMain)
        print("PASS: two real identities reuse UUIDs across dimension/HiDPI changes; virtual displays are offline and original main display is unchanged")
    }
}
