import AVFoundation
import Foundation

protocol AudioTestSoundPlaying: AnyObject {
    var onFinish: ((Bool) -> Void)? { get set }
    func play() throws
    func stop()
}

/// 普通应用音频播放，跟随系统输出；不修改设备、系统音量或 UU 的静音选项。
final class AudioTestSoundPlayer: NSObject, AudioTestSoundPlaying, AVAudioPlayerDelegate {
    enum PlaybackError: Error { case couldNotStart }
    var onFinish: ((Bool) -> Void)?
    private var player: AVAudioPlayer?

    func play() throws {
        stop()
        let player = try AVAudioPlayer(data: AudioTestTone.waveData(), fileTypeHint: AVFileType.wav.rawValue)
        player.volume = 0.6
        player.numberOfLoops = 0
        player.delegate = self
        self.player = player
        guard player.prepareToPlay(), player.play() else {
            stop()
            throw PlaybackError.couldNotStart
        }
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(player, successfully: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(player, successfully: false)
    }

    private func finish(_ player: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
            self.onFinish?(successfully)
        }
    }

    deinit { stop() }
}

/// 内置四秒双声道提示音：两组短旋律，淡入淡出避免爆音，无需外部资源。
enum AudioTestTone {
    static let duration: TimeInterval = 4
    static let sampleRate = 44_100

    static func waveData() -> Data {
        let frequencies = [523.25, 659.25, 783.99, 659.25, 523.25, 659.25, 783.99, 1046.50]
        let framesPerNote = sampleRate / 2
        let soundingFrames = Int(Double(sampleRate) * 0.36)
        let fadeFrames = Int(Double(sampleRate) * 0.015)
        let dataSize = UInt32(Int(duration) * sampleRate * 4)
        var data = Data()
        data.reserveCapacity(Int(dataSize) + 44)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(dataSize + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(2)) // 双声道，左右相同便于单侧耳机试听
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4))
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(dataSize)
        for frequency in frequencies {
            for frame in 0..<framesPerNote {
                var sample: Int16 = 0
                if frame < soundingFrames {
                    let envelope = min(1, min(Double(frame), Double(soundingFrames - 1 - frame)) / Double(fadeFrames))
                    let wave = sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate))
                    sample = Int16(wave * envelope * 0.3 * Double(Int16.max))
                }
                append(sample)
                append(sample)
            }
        }
        return data
    }
}
