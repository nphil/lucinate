import AVFoundation

/// Plays a looping silent sound so iOS keeps Lucinate (and the Phone Data engine in it) running in
/// the background. It mixes with other audio, so music keeps playing. A phone call, Siri or an
/// alarm interrupts it, and iOS does not resume it, so it restarts itself when the interruption
/// ends. Fine for a sideloaded app. App Store review would reject it.
/// `KeepAlivePolicy` says when it plays.
@MainActor
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    /// Started and not stopped, also while a call has paused it.
    var playing: Bool { player != nil }
    /// Making its sound right now. Starting it can fail, in the background say.
    var sounding: Bool { player?.isPlaying == true }

    func start() {
        if player?.isPlaying == true { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        // Nobody hears it, so latency doesn't matter. The longest buffer iOS gives wakes the CPU
        // the fewest times a second to feed the audio hardware.
        try? session.setPreferredIOBufferDuration(0.5)
        try? session.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav(seconds: 1))
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        player?.play()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                MainActor.assumeIsolated {
                    if let self { self.start() }
                }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 8-bit mono PCM at 8 kHz, every sample at the middle: silence.
    private static func silentWav(seconds: Int) -> Data {
        let rate: UInt32 = 8000
        let samples = UInt32(seconds) * rate
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate); u16(1); u16(8)
        d.append(contentsOf: Array("data".utf8)); u32(samples)
        d.append(Data(repeating: 128, count: Int(samples)))
        return d
    }
}
