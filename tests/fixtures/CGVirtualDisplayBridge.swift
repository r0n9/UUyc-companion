// 仅测试模块：模拟私有 API，生命周期测试不会创建真实显示器或改系统布局。
import CoreGraphics
import Foundation

public enum DisplaySimulation {
    public struct Creation {
        public let id: UInt32
        public let serial: UInt32
        public let name: String
        public let time: TimeInterval
    }
    public static var time: TimeInterval = 0
    public static var online: Set<UInt32> = [1]
    public static var descriptors: [UInt32: CGVirtualDisplayDescriptor] = [:]
    public static var creations: [Creation] = []
    public static var releases: [(UInt32, TimeInterval)] = []
    public static var attempts: [UInt32] = []
    public static var live: Set<UInt32> = []
    public static var removalDelay: TimeInterval = 0
    public static var pending: [UInt32: TimeInterval] = [:]
    public static var constructorFailures = 0
    public static var applyFailures = 0
    public static var nextNeverOnline = false

    public static func advance(to value: TimeInterval) {
        time = value
        for (id, deadline) in pending where deadline <= time {
            online.remove(id)
            pending[id] = nil
        }
    }
}

public final class CGVirtualDisplayDescriptor {
    public var name = ""
    public var maxPixelsWide: UInt32 = 0
    public var maxPixelsHigh: UInt32 = 0
    public var sizeInMillimeters = CGSize.zero
    public var vendorID: UInt32 = 0
    public var productID: UInt32 = 0
    public var serialNum: UInt32 = 0
    public init() {}
}

public final class CGVirtualDisplayMode {
    public init?(width: UInt, height: UInt, refreshRate: Double) {}
}

public final class CGVirtualDisplaySettings {
    public var hiDPI = false
    public var modes: [CGVirtualDisplayMode] = []
    public init() {}
}

public final class CGVirtualDisplay {
    public let displayID: UInt32
    public init?(descriptor: CGVirtualDisplayDescriptor) {
        DisplaySimulation.attempts.append(descriptor.serialNum)
        if DisplaySimulation.constructorFailures > 0 {
            DisplaySimulation.constructorFailures -= 1
            return nil
        }
        let occupied = DisplaySimulation.live.union(DisplaySimulation.online)
        precondition(!occupied.contains { DisplaySimulation.descriptors[$0]?.serialNum == descriptor.serialNum },
                     "Reused a display identity before removal")
        displayID = UInt32(DisplaySimulation.creations.count + 100)
        DisplaySimulation.descriptors[displayID] = descriptor
        DisplaySimulation.creations.append(.init(id: displayID, serial: descriptor.serialNum,
                                                name: descriptor.name, time: DisplaySimulation.time))
        DisplaySimulation.live.insert(displayID)
        if !DisplaySimulation.nextNeverOnline { DisplaySimulation.online.insert(displayID) }
        DisplaySimulation.nextNeverOnline = false
        precondition(DisplaySimulation.live.count <= 2, "Created a third live display")
    }
    public func apply(_ settings: CGVirtualDisplaySettings) -> Bool {
        if DisplaySimulation.applyFailures > 0 {
            DisplaySimulation.applyFailures -= 1
            return false
        }
        return true
    }
    deinit {
        let born = DisplaySimulation.creations.first { $0.id == displayID }!.time
        precondition(DisplaySimulation.time - born >= 2.5, "Released a young display")
        DisplaySimulation.live.remove(displayID)
        DisplaySimulation.releases.append((displayID, DisplaySimulation.time))
        DisplaySimulation.pending[displayID] = DisplaySimulation.time + DisplaySimulation.removalDelay
        DisplaySimulation.advance(to: DisplaySimulation.time)
    }
}
