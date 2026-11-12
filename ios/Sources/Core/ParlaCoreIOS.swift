import AVFoundation

// iOS stand-ins for the few macOS-only declarations that shared ParlaCore files name.
// The desktop files (AudioRecorder, ClipboardDelivery, Inserter) use AppKit/CoreAudio and are not compiled here.
public enum ClipboardRestoreMode: Sendable { case fixed, observableRequests, remoteExcluded }
/// Parakeet runs as a signed macOS helper process; iOS has no such helper, so admission always refuses.
/// Same declarations as desktop ParakeetTrust.swift, which uses macOS-only code-signing APIs.
public enum ParakeetRefusal: String, Error, Sendable {
    case needsPreparation, needsTrustedProduct, configuration, unsupportedHost, codeIdentity, resourceIdentity
}
public struct ParakeetProductIdentity: Equatable, Codable, Sendable {
    public let protocolVersion: Int
    public let adapterRevision: Int
    public let sdk: String
    public let helperSHA256: String
    public let sourceSHA256: String
    public let resources: [String: String]
    public let team: String
}
public struct ParakeetTrustedProduct: Sendable {
    public let identity: ParakeetProductIdentity
    public let executable: URL
}
public struct ParakeetTrustBottom {
    public static var system: Self { Self() }
}
public enum ParakeetTrust {
    public static func admit(expected: ParakeetProductIdentity, app: URL = Bundle.main.bundleURL,
                             bottom: ParakeetTrustBottom = .system) throws -> ParakeetTrustedProduct {
        throw ParakeetRefusal.unsupportedHost
    }
}

/// macOS Core Audio transport FourCCs named by Trace.transportName; iOS's Core Audio omits them.
private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
let kAudioDeviceTransportTypeBuiltIn = fourCC("bltn")
let kAudioDeviceTransportTypeUSB = fourCC("usb ")
let kAudioDeviceTransportTypeBluetooth = fourCC("blue")
let kAudioDeviceTransportTypeBluetoothLE = fourCC("blea")
let kAudioDeviceTransportTypeVirtual = fourCC("virt")
let kAudioDeviceTransportTypeAggregate = fourCC("grup")
let kAudioDeviceTransportTypeAirPlay = fourCC("airp")

/// Desktop keyboard shortcuts have no iOS meaning; Settings only stores this value.
public struct HotkeyBindings: Codable, Equatable, Sendable { public init() {} }
public enum Inserter {
    public enum TailSwap: Sendable { case replaced, unverified, unavailable }
}

public enum AudioRecorder {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    public enum EndReason: Equatable, Sendable { case sampleLimit, deviceLost }
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
    /// One self-contained buffer to 16 kHz mono Float32; fresh converter, drained immediately.
    public static func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let resampler = Resampler()
        return (resampler.convert(buffer) ?? []) + resampler.flush()
    }
}

/// Streaming 16 kHz mono converter. Reused across tap buffers so filter state carries over.
/// Not thread-safe; the owner serializes calls.
public final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var out: AVAudioPCMBuffer?
    public init() {}
    /// nil when the buffer could not be converted (an empty array would read as silence).
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let target = AudioRecorder.targetFormat
        if buffer.format == target, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target); inputFormat = buffer.format; out = nil
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 16
        if (out?.frameCapacity ?? 0) < capacity { out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) }
        guard let out else { return nil }
        var fed = false
        let outcome = converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard outcome != .error, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
    /// Frames still held by the converter. Call once after the last buffer.
    public func flush() -> [Float] {
        guard let converter, let out else { return [] }
        let outcome = converter.convert(to: out, error: nil) { _, status in status.pointee = .endOfStream; return nil }
        guard outcome != .error, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
