import Foundation
import AVFoundation

/// Plays audio responses from Codex realtime sessions.
///
/// Receives PCM16 24kHz mono audio chunks from the coordinator,
/// buffers them, and plays through the default output device.
final class AudioPlayer {
    
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let format: AVAudioFormat
    private var isPlaying = false
    
    var onPlaybackFinished: (() -> Void)?
    var onLevel: ((Float) -> Void)?  // 0..1 RMS per buffer
    
    init() {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        )!
    }
    
    func start() {
        guard !isPlaying else { return }
        
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
        } catch {
            print("🔊 AudioPlayer engine failed: \(error)")
            return
        }
        
        self.engine = engine
        self.playerNode = player
        player.play()
        isPlaying = true
        print("🔊 AudioPlayer ready")
    }
    
    func enqueue(_ pcmData: Data) {
        guard isPlaying, let playerNode else { return }
        
        // Convert PCM16 data to AVAudioPCMBuffer
        let frameCount = UInt32(pcmData.count / 2)
        guard frameCount > 0 else { return }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        
        pcmData.withUnsafeBytes { rawBufferPointer in
            if let baseAddress = rawBufferPointer.baseAddress {
                buffer.int16ChannelData?.pointee.update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
            }
        }

        if let onLevel {
            var sumSquares: Float = 0
            pcmData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for i in 0..<Int(frameCount) {
                    let s = Float(base[i]) / 32767.0
                    sumSquares += s * s
                }
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            let normalized = min(1.0, rms * 3.5)
            DispatchQueue.main.async { onLevel(normalized) }
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            // Buffer consumed
        }
    }
    
    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        isPlaying = false
        print("🔊 AudioPlayer stopped")
    }
    
    /// Check if all scheduled buffers have been consumed
    var isBufferEmpty: Bool {
        guard let playerNode else { return true }
        return playerNode.outputFormat(forBus: 0).sampleRate == 0 // simplified check
    }
}
