// 只读显示器身份快照，不调用 ColorSync、不创建或修改显示器。
import CoreGraphics
import Darwin
import Foundation

struct DisplayIdentity: Codable {
    let id: UInt32
    let uuid: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var count: UInt32 = 0
guard CGGetOnlineDisplayList(0, nil, &count) == .success else { fail("无法查询在线显示器") }
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { fail("无法读取在线显示器") }
typealias DisplayUUIDFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateUUIDFromDisplayID") else {
    fail("系统不提供显示器 UUID 查询接口；停止维护")
}
let displayUUID = unsafeBitCast(symbol, to: DisplayUUIDFunction.self)
let displays = ids.prefix(Int(count)).map { id -> DisplayIdentity in
    guard let uuid = displayUUID(id)?.takeRetainedValue(),
          let text = CFUUIDCreateString(nil, uuid) else { fail("显示器身份不可读：\(id)") }
    return DisplayIdentity(id: id, uuid: text as String,
                           vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id),
                           serial: CGDisplaySerialNumber(id))
}
FileHandle.standardOutput.write(try JSONEncoder().encode(displays))
