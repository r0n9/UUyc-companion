// 在独立进程中查询颜色服务，由 Python 调用方限制等待时间。
import ColorSync
import Foundation

var profiles = 0
let started = Date()
withUnsafeMutablePointer(to: &profiles) { context in
    ColorSyncIterateDeviceProfiles({ _, pointer in
        guard let pointer else { return false }
        pointer.assumingMemoryBound(to: Int.self).pointee += 1
        return true
    }, context)
}
let result: [String: Any] = ["profiles": profiles, "query_seconds": Date().timeIntervalSince(started)]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
