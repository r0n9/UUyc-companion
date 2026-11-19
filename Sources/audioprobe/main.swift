// 只读诊断：音频默认设备与屏幕拓扑；不录音、不切换输出、不改变显示配置。
import CoreAudio
import CoreGraphics
import Foundation

struct AudioDeviceSnapshot: Codable, Equatable {
    let id: AudioDeviceID
    let name: String?
    let uid: String?
    let transport: String?
    let alive: UInt32?
    let running: UInt32?
    let sampleRate: Double?
    let outputChannels: UInt32?
}

struct DisplaySnapshot: Codable, Equatable {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let main: Bool
}

struct Snapshot: Codable, Equatable {
    let defaultOutput: AudioDeviceID?
    let defaultSystemOutput: AudioDeviceID?
    let devices: [AudioDeviceSnapshot]?
    let displays: [DisplaySnapshot]?
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readUInt(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func readRate(_ object: AudioObjectID) -> Double? {
    var property = address(kAudioDevicePropertyNominalSampleRate)
    var value: Double = 0
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func outputChannels(_ object: AudioObjectID) -> UInt32? {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioBufferList>.size else { return nil }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, memory) == noErr else { return nil }
    let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + $1.mNumberChannels }
}

func transportName(_ type: UInt32?) -> String? {
    guard let type else { return nil }
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    default: return String(format: "0x%08x", type)
    }
}

func audioDevices() -> [AudioDeviceSnapshot]? {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    if !ids.isEmpty {
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
    }
    return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).sorted().map { id in
        AudioDeviceSnapshot(id: id,
                            name: readString(id, kAudioObjectPropertyName),
                            uid: readString(id, kAudioDevicePropertyDeviceUID),
                            transport: transportName(readUInt(id, kAudioDevicePropertyTransportType)),
                            alive: readUInt(id, kAudioDevicePropertyDeviceIsAlive),
                            running: readUInt(id, kAudioDevicePropertyDeviceIsRunningSomewhere),
                            sampleRate: readRate(id), outputChannels: outputChannels(id))
    }
}

func onlineDisplays() -> [DisplaySnapshot]? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.prefix(Int(count)).sorted().map {
        DisplaySnapshot(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                        main: CGDisplayIsMain($0) != 0)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
var duration: TimeInterval = 0
if !arguments.isEmpty {
    guard arguments.count == 2, arguments[0] == "--watch",
          let seconds = Double(arguments[1]), seconds.isFinite, (1...300).contains(seconds) else {
        fputs("Usage: audioprobe [--watch <seconds: 1...300>]\nRead-only JSON snapshots; no audio recording or configuration changes.\n", stderr)
        exit(2)
    }
    duration = seconds
}
setvbuf(stdout, nil, _IOLBF, 0)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let start = ProcessInfo.processInfo.systemUptime
var previous: Snapshot?
repeat {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let snapshot = Snapshot(defaultOutput: readUInt(system, kAudioHardwarePropertyDefaultOutputDevice),
                            defaultSystemOutput: readUInt(system, kAudioHardwarePropertyDefaultSystemOutputDevice),
                            devices: audioDevices(), displays: onlineDisplays())
    if snapshot != previous {
        let data = try encoder.encode(snapshot)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("\(timestamp) \(String(decoding: data, as: UTF8.self))")
        previous = snapshot
    }
    if duration == 0 { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
} while ProcessInfo.processInfo.systemUptime - start < duration
if previous?.devices?.isEmpty != false {
    fputs("No audio devices returned; this snapshot cannot confirm the actual audio route. Run outside a restricted sandbox.\n", stderr)
    exit(1)
}
