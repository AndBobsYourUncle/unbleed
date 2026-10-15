// Extract every audio track of a video file to WAV (48 kHz float): extract_tracks <video> <outprefix>
// Writes <outprefix>_track1.wav, _track2.wav, ... in the file's track order.
import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: extract_tracks <video> <outprefix>"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var tracks: [AVAssetTrack] = []
Task {
    tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    semaphore.signal()
}
semaphore.wait()
print("\(tracks.count) audio track(s)")

let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
]
for (index, track) in tracks.enumerated() {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    reader.startReading()
    var file: AVAudioFile?
    var frames = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { continue }
        let format = AVAudioFormat(streamDescription: asbd)!
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { continue }
        buffer.frameLength = n
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n), into: buffer.mutableAudioBufferList)
        if file == nil {
            file = try AVAudioFile(forWriting: URL(fileURLWithPath: "\(args[2])_track\(index + 1).wav"),
                                   settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        }
        try file?.write(from: buffer)
        frames += Int(n)
    }
    file = nil  // finalize
    print("track \(index + 1): \(String(format: "%.1f", Double(frames) / 48000)) s, \(track.formatDescriptions.count) format(s)")
}
