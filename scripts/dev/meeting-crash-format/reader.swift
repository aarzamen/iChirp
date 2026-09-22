// M3 Step 1 harness (see run.sh). Usage: reader <path>. Prints the readable duration after a kill.
import AVFoundation
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
var line = "\(url.lastPathComponent) bytes=\(size)"
if let file = try? AVAudioFile(forReading: url) {
    line += String(format: " AVAudioFile=%.2fs", Double(file.length) / file.fileFormat.sampleRate)
    // Decode everything to be sure the frames are really readable.
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    var decoded = 0
    while file.framePosition < file.length {
        do { try file.read(into: buf) } catch { line += " readErr"; break }
        if buf.frameLength == 0 { break }
        decoded += Int(buf.frameLength)
    }
    line += String(format: " decoded=%.2fs", Double(decoded) / file.processingFormat.sampleRate)
} else {
    line += " AVAudioFile=UNREADABLE"
}
let asset = AVURLAsset(url: url)
let sem = DispatchSemaphore(value: 0)
Task {
    let d = try? await asset.load(.duration)
    line += String(format: " asset=%.2fs", d.map { CMTimeGetSeconds($0) } ?? -1)
    sem.signal()
}
sem.wait()
print(line)
