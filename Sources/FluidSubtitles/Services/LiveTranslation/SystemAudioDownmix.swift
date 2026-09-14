import CoreAudio
import Foundation

/// Converts ScreenCaptureKit / Core Audio buffer lists to mono float.
/// Does not assume interleaved layout or a fixed channel count.
enum SystemAudioDownmix {
    static func monoSamples(
        asbd: AudioStreamBasicDescription,
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int
    ) -> [Float]? {
        guard frameCount > 0, asbd.mSampleRate > 0 else { return nil }
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard list.count > 0 else { return nil }

        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
           asbd.mBitsPerChannel == 32
        {
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                return self.averageNonInterleavedFloat(list: list, frameCount: frameCount, channels: channels)
            }
            return self.averageInterleavedFloat(list: list, frameCount: frameCount, channels: channels)
        }

        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mBitsPerChannel == 16,
           asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0
        {
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                return self.averageNonInterleavedInt16(list: list, frameCount: frameCount, channels: channels)
            }
            return self.averageInterleavedInt16(list: list, frameCount: frameCount, channels: channels)
        }
        return nil
    }

    private static func averageNonInterleavedFloat(
        list: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channels: Int
    ) -> [Float]? {
        let used = min(channels, list.count)
        guard used > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frameCount)
        var validChannels = 0
        for channel in 0..<used {
            guard let data = list[channel].mData else { continue }
            let pointer = data.assumingMemoryBound(to: Float.self)
            let available = Int(list[channel].mDataByteSize) / MemoryLayout<Float>.size
            let count = min(frameCount, available)
            for index in 0..<count {
                let sample = pointer[index]
                if sample.isFinite {
                    mono[index] += sample
                }
            }
            validChannels += 1
        }
        guard validChannels > 0 else { return nil }
        if validChannels > 1 {
            let scale = 1 / Float(validChannels)
            for index in 0..<frameCount {
                mono[index] *= scale
            }
        }
        return mono
    }

    private static func averageInterleavedFloat(
        list: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channels: Int
    ) -> [Float]? {
        guard let data = list[0].mData else { return nil }
        let pointer = data.assumingMemoryBound(to: Float.self)
        let available = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        let frames = min(frameCount, available / max(channels, 1))
        guard frames > 0 else { return nil }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: pointer, count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let sample = pointer[frame * channels + channel]
                if sample.isFinite {
                    sum += sample
                }
            }
            mono[frame] = sum * scale
        }
        return mono
    }

    private static func averageNonInterleavedInt16(
        list: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channels: Int
    ) -> [Float]? {
        let used = min(channels, list.count)
        guard used > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frameCount)
        var validChannels = 0
        let scale = 1 / Float(Int16.max)
        for channel in 0..<used {
            guard let data = list[channel].mData else { continue }
            let pointer = data.assumingMemoryBound(to: Int16.self)
            let available = Int(list[channel].mDataByteSize) / MemoryLayout<Int16>.size
            let count = min(frameCount, available)
            for index in 0..<count {
                mono[index] += Float(pointer[index]) * scale
            }
            validChannels += 1
        }
        guard validChannels > 0 else { return nil }
        if validChannels > 1 {
            let mix = 1 / Float(validChannels)
            for index in 0..<frameCount {
                mono[index] *= mix
            }
        }
        return mono
    }

    private static func averageInterleavedInt16(
        list: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channels: Int
    ) -> [Float]? {
        guard let data = list[0].mData else { return nil }
        let pointer = data.assumingMemoryBound(to: Int16.self)
        let available = Int(list[0].mDataByteSize) / MemoryLayout<Int16>.size
        let frames = min(frameCount, available / max(channels, 1))
        guard frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / (Float(channels) * Float(Int16.max))
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += Float(pointer[frame * channels + channel])
            }
            mono[frame] = sum * scale
        }
        return mono
    }
}
