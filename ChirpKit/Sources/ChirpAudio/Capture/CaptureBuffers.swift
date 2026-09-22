// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/AudioRecorder.swift @ bbae9e0e
// Changes: the free buffer helpers only (`copyPCMBufferForAsyncUse`, `extractChannelZero`,
// `microphoneCaptureMonoBuffer`, the downmix with its cancellation guard, and `convertDictationBuffer`'s
// `AVAudioConverter` handling including the `.inputRanDry` partial-output rule), without diagnostics plumbing.

import AVFoundation
import Foundation
import Synchronization

/// Copies a tap buffer so it can be processed off the render thread (the tap's buffer is valid only during the call).
func copyPCMBufferForAsyncUse(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else {
        return nil
    }
    copy.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return copy }

    if buffer.format.isInterleaved {
        let source = buffer.audioBufferList.pointee.mBuffers
        let destination = copy.mutableAudioBufferList.pointee.mBuffers
        let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
        guard byteCount > 0 else { return copy }
        guard let sourceData = source.mData, let destinationData = destination.mData else { return nil }
        destinationData.copyMemory(from: sourceData, byteCount: byteCount)
        return copy
    }
    let channelCount = Int(buffer.format.channelCount)
    if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
        for channel in 0..<channelCount { destination[channel].update(from: source[channel], count: frameCount) }
        return copy
    }
    if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
        for channel in 0..<channelCount { destination[channel].update(from: source[channel], count: frameCount) }
        return copy
    }
    if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
        for channel in 0..<channelCount { destination[channel].update(from: source[channel], count: frameCount) }
        return copy
    }
    return nil
}

/// The mono buffer the recorder converts. Under voice processing Core Audio puts the processed signal on channel 0
/// (the other channels are references), so only channel 0 is kept; raw input downmixes every channel so a
/// multichannel interface works even when the microphone is not on channel 1.
func microphoneCaptureMonoBuffer(from buffer: AVAudioPCMBuffer, extractVoiceProcessingChannelZero: Bool)
    -> AVAudioPCMBuffer?
{
    extractVoiceProcessingChannelZero ? extractChannelZero(from: buffer) : downmixChannelsToMono(from: buffer)
}

/// Channel 0 of a non-interleaved buffer as a mono buffer. Mono input is returned as is; interleaved multichannel
/// input (rare) is passed through for the converter to mix, as upstream does.
func extractChannelZero(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let inputFormat = buffer.format
    if inputFormat.channelCount == 1 || inputFormat.isInterleaved { return buffer }
    guard
        let monoFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat, sampleRate: inputFormat.sampleRate, channels: 1,
            interleaved: false),
        let extracted = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity)
    else { return nil }
    extracted.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    if let source = buffer.floatChannelData, let destination = extracted.floatChannelData {
        destination[0].update(from: source[0], count: frameCount)
        return extracted
    }
    if let source = buffer.int16ChannelData, let destination = extracted.int16ChannelData {
        destination[0].update(from: source[0], count: frameCount)
        return extracted
    }
    if let source = buffer.int32ChannelData, let destination = extracted.int32ChannelData {
        destination[0].update(from: source[0], count: frameCount)
        return extracted
    }
    return nil
}

/// The mean of every channel as mono Float32, or nil for an unsupported sample format.
func downmixChannelsToMono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let inputFormat = buffer.format
    let channelCount = Int(inputFormat.channelCount)
    guard channelCount > 0 else { return nil }
    if channelCount == 1 { return buffer }
    guard
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
        let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
        let destination = mixed.floatChannelData?[0]
    else { return nil }
    mixed.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return mixed }

    let interleaved = inputFormat.isInterleaved
    let raw = buffer.audioBufferList.pointee.mBuffers.mData
    switch inputFormat.commonFormat {
    case .pcmFormatFloat32:
        if interleaved {
            guard let source = raw?.assumingMemoryBound(to: Float.self) else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination) { Double(source[$0 * channelCount + $1]) }
        } else {
            guard let source = buffer.floatChannelData else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination) { Double(source[$1][$0]) }
        }
    case .pcmFormatInt16:
        let scale = Float(Int16.max)
        if interleaved {
            guard let source = raw?.assumingMemoryBound(to: Int16.self) else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination, scale) {
                Double(source[$0 * channelCount + $1])
            }
        } else {
            guard let source = buffer.int16ChannelData else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination, scale) { Double(source[$1][$0]) }
        }
    case .pcmFormatInt32:
        let scale = Float(Int32.max)
        if interleaved {
            guard let source = raw?.assumingMemoryBound(to: Int32.self) else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination, scale) {
                Double(source[$0 * channelCount + $1])
            }
        } else {
            guard let source = buffer.int32ChannelData else { return nil }
            fillDownmixedSamples(channelCount, frameCount, destination, scale) { Double(source[$1][$0]) }
        }
    default:
        return nil
    }
    return mixed
}

/// The ordinary mean, unless the channels destructively cancel over the whole buffer: then the loudest channel alone
/// supplies every frame (upstream's guard against phase-inverted pairs).
@inline(__always)
private func fillDownmixedSamples(
    _ channelCount: Int, _ frameCount: Int, _ destination: UnsafeMutablePointer<Float>,
    _ normalization: Float = 1, sample: (Int, Int) -> Double
) {
    var inputEnergy = 0.0
    var summedEnergy = 0.0
    for frame in 0..<frameCount {
        var sum: Float = 0
        var energySum = 0.0
        for channel in 0..<channelCount {
            let value = sample(frame, channel)
            sum += Float(value) / normalization
            energySum += value
            inputEnergy += value * value
        }
        destination[frame] = sum / Float(channelCount)
        summedEnergy += energySum * energySum
    }
    guard inputEnergy > 0, inputEnergy.isFinite, summedEnergy.isFinite, summedEnergy < 0.25 * inputEnergy else {
        return
    }
    var dominantChannel = 0
    var dominantEnergy = -1.0
    for channel in 0..<channelCount {
        var energy = 0.0
        for frame in 0..<frameCount {
            let value = sample(frame, channel)
            energy += value * value
        }
        if energy > dominantEnergy {
            dominantChannel = channel
            dominantEnergy = energy
        }
    }
    for frame in 0..<frameCount {
        destination[frame] = Float(sample(frame, dominantChannel)) / normalization
    }
}

/// Converts mono microphone buffers to 16 kHz mono Float32, rebuilding the converter whenever the input format
/// changes (a route change can switch 48 kHz to AirPods' 24 kHz mid-recording). Not thread-safe: one per recording,
/// used from one queue.
final class SpeechRateConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// The converted audio, or nil when nothing came out (or the converter failed).
    func convert(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = mono.format
        if inputFormat.commonFormat == outputFormat.commonFormat, inputFormat.sampleRate == outputFormat.sampleRate,
            inputFormat.channelCount == 1
        {
            return mono
        }
        if sourceFormat?.isEqual(inputFormat) != true {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            // Live chunks cannot supply the read-ahead frames a primed converter waits for.
            converter?.primeMethod = .none
            sourceFormat = inputFormat
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(
            (Double(mono.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate).rounded(.up))
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        // The input block is `@Sendable`; it runs synchronously inside `convert`, once per request for input.
        let input = UncheckedBuffer(mono)
        let consumed = Mutex(false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            let isFirst = consumed.withLock { wasConsumed in
                defer { wasConsumed = true }
                return !wasConsumed
            }
            guard isFirst else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input.buffer
        }
        switch status {
        case .haveData:
            return output
        case .inputRanDry:
            // A stateful rate converter can use all the input and return a partial buffer; dropping it would lose
            // a third of the speech at 24 kHz (upstream).
            return output.frameLength > 0 ? output : nil
        default:
            return nil
        }
    }
}
