import Foundation
import CoreAudio
import AudioToolbox

/// Captures microphone audio via Core Audio AudioDevice IO proc.
///
/// Bypasses AVAudioEngine entirely — goes straight to the hardware via
/// AudioDeviceCreateIOProcID. Works at any sample rate (24kHz or 48kHz)
/// since there's no format matching layer to crash.
final class AudioCapture {
    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var chunkCount = 0
    private var callbackFired = false
    private var hwSampleRate: Float64 = 48000
    private var hwFormat: AudioStreamBasicDescription?

    static let targetSampleRate: Double = 24000.0
    var onAudioData: ((Data) -> Void)?
    var isRunning: Bool { procID != nil }

    // MARK: - Device Discovery

    /// List available audio input devices.
    struct InputDevice: Identifiable, Hashable {
        let id: UInt32  // AudioObjectID
        let uid: String  // kAudioDevicePropertyDeviceUID
        let name: String
    }

    /// Query all available input devices.
    static func listInputDevices() -> [InputDevice] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get size first
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(propSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [InputDevice] = []
        for id in deviceIDs {
            // Check if device has input streams
            var inputSize: UInt32 = 0
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let streamStatus = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &inputSize)
            guard streamStatus == noErr, inputSize > 0 else { continue }

            // Get device name
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid)

            devices.append(InputDevice(
                id: id,
                uid: uid as String,
                name: name as String
            ))
        }
        return devices
    }

    func start() throws {
        // 1. Get default input device
        var propSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            print("⚠️ No default input device (status=\(status))")
            throw AudioError.noInputDevice
        }

        // 2. Get device sample rate
        propSize = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        address.mScope = kAudioObjectPropertyScopeGlobal
        address.mElement = kAudioObjectPropertyElementMain
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &hwSampleRate)
        print("🎤 Device \(deviceID): \(hwSampleRate)Hz")

        // 3. Get the physical stream format (input scope, element 1)
        var asbd = AudioStreamBasicDescription()
        propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioStreamPropertyPhysicalFormat
        address.mScope = kAudioDevicePropertyScopeInput
        address.mElement = 1
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &asbd)
        if status == noErr {
            hwFormat = asbd
            print("🎤 Stream: \(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, fmt=\(fourCC(asbd.mFormatID)), flags=\(asbd.mFormatFlags), bits=\(asbd.mBitsPerChannel), bytes/frame=\(asbd.mBytesPerFrame)")
        } else {
            print("⚠️ Could not get stream format (status=\(status)), assuming float32")
        }

        // 4. Create IO proc
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(deviceID, ioCallback, selfPtr, &newProcID)
        guard status == noErr, let pid = newProcID else {
            print("⚠️ AudioDeviceCreateIOProcID failed: \(status)")
            throw AudioError.unsupportedFormat
        }
        self.procID = pid

        // 5. Start
        status = AudioDeviceStart(deviceID, pid)
        guard status == noErr else {
            print("⚠️ AudioDeviceStart failed: \(status)")
            AudioDeviceDestroyIOProcID(deviceID, pid)
            self.procID = nil
            throw AudioError.noInputDevice
        }

        chunkCount = 0
        callbackFired = false
        print("🎙️ CoreAudio IO started")
    }

    func stop() {
        if let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
        }
        procID = nil
        print("🛑 Audio stopped. \(chunkCount) chunks.")
        chunkCount = 0
        callbackFired = false
    }

    // MARK: - IO Callback (called from Core Audio real-time thread)

    func processInput(inputData: UnsafePointer<AudioBufferList>) {
        let bufferList = inputData.pointee
        guard bufferList.mNumberBuffers > 0 else { return }

        let buf = bufferList.mBuffers
        guard buf.mDataByteSize > 0, let dataPtr = buf.mData else { return }

        if !callbackFired {
            callbackFired = true
            print("🎙️ IO CALLBACK FIRED! bytes=\(buf.mDataByteSize), ch=\(buf.mNumberChannels)")
        }

        // Determine format from hwFormat
        let isFloat = hwFormat.map { $0.mFormatFlags & UInt32(kAudioFormatFlagIsFloat) != 0 } ?? true

        if isFloat {
            processFloat32(dataPtr: dataPtr, byteCount: Int(buf.mDataByteSize))
        } else {
            processInt16(dataPtr: dataPtr, byteCount: Int(buf.mDataByteSize))
        }
    }

    private func processFloat32(dataPtr: UnsafeMutableRawPointer, byteCount: Int) {
        let frameCount = byteCount / 4
        guard frameCount > 0 else { return }

        let floatPtr = dataPtr.assumingMemoryBound(to: Float.self)
        let ratio = Float(Self.targetSampleRate / hwSampleRate)
        let outputCount = Int(Float(frameCount) * ratio)
        guard outputCount > 0 else { return }

        var pcm16 = Data(capacity: outputCount * 2)
        for i in 0..<outputCount {
            let srcIdx = min(Int(Float(i) / ratio), frameCount - 1)
            let sample = floatPtr[srcIdx]
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            pcm16.append(contentsOf: withUnsafeBytes(of: intSample.littleEndian) { Array($0) })
        }

        emitChunk(pcm16, inputFrames: frameCount, outputFrames: outputCount)
    }

    private func processInt16(dataPtr: UnsafeMutableRawPointer, byteCount: Int) {
        let frameCount = byteCount / 2
        guard frameCount > 0 else { return }

        let int16Ptr = dataPtr.assumingMemoryBound(to: Int16.self)
        let ratio = Float(Self.targetSampleRate / hwSampleRate)
        let outputCount = Int(Float(frameCount) * ratio)
        guard outputCount > 0 else { return }

        var pcm16 = Data(capacity: outputCount * 2)
        for i in 0..<outputCount {
            let srcIdx = min(Int(Float(i) / ratio), frameCount - 1)
            pcm16.append(contentsOf: withUnsafeBytes(of: int16Ptr[srcIdx].littleEndian) { Array($0) })
        }

        emitChunk(pcm16, inputFrames: frameCount, outputFrames: outputCount)
    }

    private func emitChunk(_ data: Data, inputFrames: Int, outputFrames: Int) {
        guard !data.isEmpty else { return }
        chunkCount += 1
        if chunkCount == 1 {
            print("🎙️ First chunk: \(data.count) bytes (\(outputFrames) from \(inputFrames) @ \(Int(hwSampleRate))Hz)")
        }
        onAudioData?(data)
    }

    private func fourCC(_ code: UInt32) -> String {
        let bytes: [CChar] = [
            CChar(truncatingIfNeeded: (code >> 24) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 16) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 8) & 0xFF),
            CChar(truncatingIfNeeded: code & 0xFF),
            0
        ]
        return String(cString: bytes)
    }
}

// MARK: - C-compatible IO callback (free function)

private func ioCallback(
    device: AudioObjectID,
    currentTime: UnsafePointer<AudioTimeStamp>,
    inputData: UnsafePointer<AudioBufferList>,
    inputTime: UnsafePointer<AudioTimeStamp>,
    outputData: UnsafeMutablePointer<AudioBufferList>,
    outputTime: UnsafePointer<AudioTimeStamp>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let capture = Unmanaged<AudioCapture>.fromOpaque(clientData).takeUnretainedValue()
    capture.processInput(inputData: inputData)
    return noErr
}

enum AudioError: LocalizedError {
    case unsupportedFormat
    case permissionDenied
    case notRunning
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Cannot create audio IO proc"
        case .permissionDenied: return "Microphone permission denied"
        case .notRunning: return "Audio capture not running"
        case .noInputDevice: return "No microphone detected"
        }
    }
}
