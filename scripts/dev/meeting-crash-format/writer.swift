// M3 Step 1 harness (see run.sh). Usage: writer <fmp4|caf|wav|m4a-plain> <path> <seconds> [killAfterSeconds]
import AVFoundation
import CoreMedia
import Foundation

// Usage: writer <format: fmp4|caf|wav|m4a-plain> <path> <seconds>
let args = CommandLine.arguments
let format = args[1]
let url = URL(fileURLWithPath: args[2])
let seconds = Double(args[3]) ?? 30
let killAfter = args.count > 4 ? Double(args[4])! : -1
func maybeDie() { if killAfter > 0, Double(total) >= killAfter * rate { kill(getpid(), SIGKILL) } }
let rate = 16_000.0
let frames: AVAudioFrameCount = 4096
let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
try? FileManager.default.removeItem(at: url)

func makeBuffer(_ index: Int) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames)!
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) {
        let t = Double(index * Int(frames) + i) / rate
        data[i] = Float(0.3 * sin(2 * .pi * 440 * t))
    }
    return buffer
}

var total = 0
let bufferCount = Int(seconds * rate / Double(frames))
switch format {
case "fmp4":
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
    writer.initialMovieFragmentInterval = CMTime(value: 1, timescale: 1)
    writer.shouldOptimizeForNetworkUse = false
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    guard writer.startWriting() else { print("start failed \(String(describing: writer.error))"); exit(2) }
    writer.startSession(atSourceTime: .zero)
    var desc: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.streamDescription, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
    for i in 0..<bufferCount {
        let buffer = makeBuffer(i)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(total), timescale: Int32(rate)), decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: desc, sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, bufferList: buffer.audioBufferList)
        while !input.isReadyForMoreMediaData { usleep(1000) }
        if !input.append(sample!) { print("append failed \(String(describing: writer.error))"); exit(3) }
        total += Int(frames)
        maybeDie()
        if ProcessInfo.processInfo.environment["NOPACE"] == nil { usleep(useconds_t(Double(frames) / rate * 1_000_000)) }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
case "caf", "wav", "m4a-plain":
    var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
    if format == "m4a-plain" {
        settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    } else {
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    for i in 0..<bufferCount {
        try file.write(from: makeBuffer(i))
        total += Int(frames)
        maybeDie()
        if ProcessInfo.processInfo.environment["NOPACE"] == nil { usleep(useconds_t(Double(frames) / rate * 1_000_000)) }
    }
default:
    print("unknown format"); exit(1)
}
print("finished \(total)")
