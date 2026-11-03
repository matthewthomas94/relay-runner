import AudioToolbox
import Foundation
import RelayRemoteProtocol

/// Plays the Mac's voice (RR-458): AAC-LC in ADTS framing, appended in slices
/// cut anywhere, parsed by `AudioFileStream` and decoded and played gaplessly by
/// one `AudioQueue` per stream. It does not manage the audio session; the app's
/// `AudioSessionController` keeps it active while the playback queue is busy,
/// which also keeps a reply playing with the screen locked.
@MainActor
public final class AudioQueueSpeechPlayer: SpeechAudioPlaying {
    /// Output gain, 0...1. Tests play at 0.
    public var volume: Float = 1
    public private(set) var isPaused = false

    private var fileStream: AudioFileStreamID?
    private var audioQueue: AudioQueueRef?
    private var completion: (@MainActor (AudioPlaybackEnd) -> Void)?
    private var ended = false
    private var running = false
    private var enqueued = 0
    private static let callbackQueue = DispatchQueue(label: "relay-remote.speech-audio")

    public init() {}

    deinit {
        // Callbacks reach this object through an unretained pointer, so tear
        // the queue down before it goes away.
        if let audioQueue {
            AudioQueueDispose(audioQueue, true)
        }
        if let fileStream {
            AudioFileStreamClose(fileStream)
        }
    }

    public func startStream(format: AudioFormat, sampleRate: Int,
                            completion: @escaping @MainActor (AudioPlaybackEnd) -> Void) {
        finish(.stopped)
        self.completion = completion
        ended = false
        running = false
        enqueued = 0
        guard format == .aac else { return finish(.failed) }
        var stream: AudioFileStreamID?
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), streamPropertyChanged,
                                         streamPacketsReady, kAudioFileAAC_ADTSType, &stream)
        guard status == noErr, let stream else { return finish(.failed) }
        fileStream = stream
    }

    public func append(_ data: Data) {
        guard let fileStream, !ended, !data.isEmpty else { return }
        let status = data.withUnsafeBytes { bytes in
            AudioFileStreamParseBytes(fileStream, UInt32(bytes.count), bytes.baseAddress!, [])
        }
        if status != noErr { finish(.failed) }
    }

    public func endStream() {
        guard completion != nil, !ended else { return }
        ended = true
        guard let audioQueue, enqueued > 0 else { return finish(.failed) }
        if !isPaused { drain(audioQueue) }
    }

    public func stop() {
        finish(.stopped)
    }

    /// An audio session interruption began.
    public func pause() {
        isPaused = true
        if let audioQueue { AudioQueuePause(audioQueue) }
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        guard let audioQueue, enqueued > 0 else { return }
        if ended {
            drain(audioQueue)
        } else if AudioQueueStart(audioQueue, nil) != noErr {
            finish(.failed)
        }
    }

    // MARK: - Internals

    /// Plays what is queued, then stops; `queueRunningChanged` reports the end.
    private func drain(_ queue: AudioQueueRef) {
        if !running, AudioQueueStart(queue, nil) != noErr { return finish(.failed) }
        AudioQueueFlush(queue)
        AudioQueueStop(queue, false)
    }

    private func finish(_ end: AudioPlaybackEnd) {
        if let audioQueue {
            AudioQueueRemovePropertyListener(audioQueue, kAudioQueueProperty_IsRunning, queueRunningChanged, nil)
            AudioQueueDispose(audioQueue, true)
            Self.live[UInt(bitPattern: audioQueue)] = nil
            self.audioQueue = nil
        }
        if let fileStream {
            AudioFileStreamClose(fileStream)
            self.fileStream = nil
        }
        running = false
        isPaused = false
        guard let completion else { return }
        self.completion = nil
        completion(end)
    }

    fileprivate func propertyChanged(_ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets, audioQueue == nil,
              let fileStream else { return }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_DataFormat, &size, &format) == noErr
        else { return finish(.failed) }
        var queue: AudioQueueRef?
        // Not the main queue: disposing from main waits for this queue to drain.
        let status = AudioQueueNewOutputWithDispatchQueue(&queue, &format, 0, Self.callbackQueue) { queue, buffer in
            AudioQueueFreeBuffer(queue, buffer)
        }
        guard status == noErr, let queue else { return finish(.failed) }
        audioQueue = queue
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
                AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, cookie, cookieSize)
            }
        }
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, volume)
        Self.live[UInt(bitPattern: queue)] = WeakPlayer(player: self)
        AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, queueRunningChanged, nil)
    }

    fileprivate func packetsReady(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer,
                                  descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let audioQueue, bytes > 0, packets > 0 else { return }
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBufferWithPacketDescriptions(audioQueue, bytes, descriptions == nil ? 0 : packets,
                                                             &buffer) == noErr,
              let buffer else { return finish(.failed) }
        buffer.pointee.mAudioData.copyMemory(from: data, byteCount: Int(bytes))
        buffer.pointee.mAudioDataByteSize = bytes
        if let descriptions, let target = buffer.pointee.mPacketDescriptions {
            target.update(from: descriptions, count: Int(packets))
            buffer.pointee.mPacketDescriptionCount = packets
        }
        guard AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil) == noErr else { return finish(.failed) }
        enqueued += 1
        if !running, !isPaused {
            guard AudioQueueStart(audioQueue, nil) == noErr else { return finish(.failed) }
            running = true
        }
    }

    private struct WeakPlayer {
        weak var player: AudioQueueSpeechPlayer?
    }

    /// Players by queue address, so a late `IsRunning` callback never touches
    /// a player that is gone.
    private static var live: [UInt: WeakPlayer] = [:]

    fileprivate static func runningChanged(queueAddress: UInt) {
        guard let player = live[queueAddress]?.player, let queue = player.audioQueue,
              UInt(bitPattern: queue) == queueAddress else { return }
        player.runningChanged(queue)
    }

    private func runningChanged(_ queue: AudioQueueRef) {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size)
        running = value != 0
        if !running, ended, !isPaused { finish(.finished) }
    }
}

// AudioFileStream calls these synchronously inside `AudioFileStreamParseBytes`,
// which the player only calls on the main actor.
private func streamPropertyChanged(_ client: UnsafeMutableRawPointer, _ stream: AudioFileStreamID,
                                   _ property: AudioFileStreamPropertyID,
                                   _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    let player = Unmanaged<AudioQueueSpeechPlayer>.fromOpaque(client).takeUnretainedValue()
    MainActor.assumeIsolated { player.propertyChanged(property) }
}

private func streamPacketsReady(_ client: UnsafeMutableRawPointer, _ bytes: UInt32, _ packets: UInt32,
                                _ data: UnsafeRawPointer,
                                _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    let player = Unmanaged<AudioQueueSpeechPlayer>.fromOpaque(client).takeUnretainedValue()
    MainActor.assumeIsolated {
        player.packetsReady(bytes: bytes, packets: packets, data: data, descriptions: descriptions)
    }
}

// AudioQueue calls this on its own thread; the player is looked up on main.
private func queueRunningChanged(_ client: UnsafeMutableRawPointer?, _ queue: AudioQueueRef,
                                 _ property: AudioQueuePropertyID) {
    let queueAddress = UInt(bitPattern: queue)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { AudioQueueSpeechPlayer.runningChanged(queueAddress: queueAddress) }
    }
}
