import CoreAudio
import Foundation

/// Env-gated latency trace: one greppable line per dictation on stderr.
///
/// Off by default and off cheaply — `enabled` is read from the environment once
/// and cached, so every call site is a bool test and a return. That matters
/// because one of the stamps is taken on the realtime audio thread, which must
/// not allocate or block when nobody is measuring.
///
/// With PARLA_TRACE=1 the recording path does take a lock and a dictionary
/// insert on the audio thread. ponytail: acceptable — the trace exists to be
/// switched on for a measurement session, not to run in production.
public final class Trace: @unchecked Sendable {
    /// Pipeline order is the declaration order; the emitted line is sorted by
    /// timestamp so an out-of-order stamp shows up rather than being hidden.
    public enum Stamp: String {
        case fnDown = "fn_down"
        case recorderStartReturned = "recorder_start_returned"
        case firstPCM = "first_pcm_callback"
        case fnUp = "fn_up"
        case finalPassDone = "final_pass_done"
        case landed = "landed"
        case cleanedSwapped = "cleaned_swapped"
    }

    /// Read once, cached for the process lifetime.
    public static let enabled = ProcessInfo.processInfo.environment["PARLA_TRACE"] == "1"

    static let shared = Trace()

    private let lock = NSLock()
    private var stamps: [Stamp: UInt64] = [:]
    private var transport = "unknown"

    public init() { stamps.reserveCapacity(8) }

    // MARK: - Recording (instance API — the tests drive this one directly)

    /// First stamp wins: the audio tap calls `.firstPCM` on every buffer, and a
    /// re-stamped name would report the last buffer instead of the first.
    /// `.fnDown` is the exception — it starts a new dictation, so it clears.
    /// `at` is injectable so tests don't race a real clock; the default is
    /// monotonic (Date jumps with NTP and would poison a delta).
    public func mark(_ stamp: Stamp, at ns: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        if stamp == .fnDown { stamps.removeAll(keepingCapacity: true) }
        if stamps[stamp] == nil { stamps[stamp] = ns }
    }

    public func setTransport(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        transport = name
    }

    /// The formatted line for this dictation, clearing the stamps. Empty when
    /// nothing was stamped.
    public func take() -> String {
        lock.lock()
        let pairs = stamps.map { ($0.key.rawValue, $0.value) }
        let transport = self.transport
        stamps.removeAll(keepingCapacity: true)
        lock.unlock()
        return Trace.line(stamps: pairs, transport: transport)
    }

    /// `parla-trace transport=usb fn_down=0ms first_pcm_callback=+88.1ms … total=…`
    /// Each value is the delta from the previous stamp, so the line reads as a
    /// budget; `total` spans first to last.
    public static func line(stamps: [(String, UInt64)], transport: String) -> String {
        let ordered = stamps.sorted { $0.1 < $1.1 }
        guard let first = ordered.first else { return "" }
        func ms(_ ns: UInt64) -> String { String(format: "%.1f", Double(ns) / 1_000_000) }
        var parts = ["parla-trace", "transport=\(transport)", "\(first.0)=0ms"]
        for (prev, cur) in zip(ordered, ordered.dropFirst()) {
            parts.append("\(cur.0)=+\(ms(cur.1 - prev.1))ms")
        }
        parts.append("total=\(ms(ordered[ordered.count - 1].1 - first.1))ms")
        return parts.joined(separator: " ")
    }

    /// Core Audio transport type → short label. Bluetooth alone moves
    /// press→first-sample by hundreds of ms (docs/research/03-latency.md §1),
    /// so a trace that omits the transport is misleading rather than merely thin.
    public static func transportName(_ raw: UInt32) -> String {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth_le"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        default: return "unknown"
        }
    }

    // MARK: - Static facade (call sites) — every entry point returns when disabled

    public static func mark(_ stamp: Stamp) {
        guard enabled else { return }
        shared.mark(stamp)
    }

    public static func setTransport(_ name: String) {
        guard enabled else { return }
        shared.setTransport(name)
    }

    /// One line per dictation, on stderr so it never mixes into stdout output.
    public static func flush() {
        guard enabled else { return }
        let line = shared.take()
        guard !line.isEmpty else { return }
        fputs(line + "\n", stderr)
    }
}
