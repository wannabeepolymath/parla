import AppKit
import Carbon

/// Labels only. Neither this lookup nor the selected input source participates in
/// KeyChord serialization, validation rules or physical event matching.
public struct ShortcutDisplayFormatter {
    private let lookup: (UInt16) -> String?

    public init(lookup: @escaping (UInt16) -> String?) { self.lookup = lookup }

    public func display(_ chord: KeyChord) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.fn) { parts.append("fn") }
        if chord.modifiers.contains(.ctrl) { parts.append("⌃") }
        if chord.modifiers.contains(.opt) { parts.append("⌥") }
        if chord.modifiers.contains(.shift) { parts.append("⇧") }
        if chord.modifiers.contains(.cmd) { parts.append("⌘") }
        let canonical = KeyChord.names[chord.keyCode]
        if let canonical, canonical.count > 1 {
            parts.append(canonical) // modifiers, navigation, Space, F-keys, etc.
        } else if let label = lookup(chord.keyCode), Self.isPrintableLabel(label) {
            parts.append(label)
        } else if let canonical {
            parts.append("\(canonical) (physical key \(chord.keyCode))")
        } else {
            parts.append("Physical key \(chord.keyCode)")
        }
        return parts.joined(separator: " ")
    }

    private static func isPrintableLabel(_ label: String) -> Bool {
        // A base key label may be a composed Unicode grapheme, never a text-input
        // sequence, control code, invisible format character or whitespace.
        label.count == 1 && label.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                && ![.format, .privateUse, .unassigned, .surrogate].contains($0.properties.generalCategory)
                && $0.value != 0xFFFD
        }
    }

    /// Snapshot the selected source itself, not an IME's underlying/fallback US
    /// layout. Missing Unicode layout data deliberately gives physical labels.
    public static func current() -> Self {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return Self { _ in nil } }
        let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        let data = property.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
        return keyboardLayout(data: data, keyboardType: UInt32(LMGetKbdType()))
    }

    /// Keep the selected source's native-endian 'uchr' data alive for lookup.
    /// Carbon's declared default table covers ordinary ANSI positions, but does
    /// not establish extra ISO/JIS positions without a hardware-type mapping.
    static func keyboardLayout(data: Data?, keyboardType: UInt32?) -> Self {
        guard let data, let keyboardType, keyboardType != 0,
              let coverage = keyboardCoverage(keyboardType, data: data),
              coverage.exact || coverage.generic else { return Self { _ in nil } }
        return Self { code in
            guard code < 128, coverage.exact || KeyChord.names[code]?.count == 1 else { return nil }
            return data.withUnsafeBytes { bytes in
                var state: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 16)
                let status = UCKeyTranslate(bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                    code, UInt16(kUCKeyActionDisplay), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &state, characters.count, &length, &characters)
                guard status == noErr, state == 0, length > 0, length <= characters.count else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }

    private static func keyboardCoverage(_ type: UInt32, data: Data) -> (exact: Bool, generic: Bool)? {
        // UCKeyboardLayout's fixed header is 12 bytes followed by type headers.
        guard data.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
        return data.withUnsafeBytes { bytes in
            let count = Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let stride = MemoryLayout<UCKeyboardTypeHeader>.stride
            guard count > 0, count <= (data.count - 12) / stride else { return nil }
            let first = bytes.loadUnaligned(fromByteOffset: 12, as: UCKeyboardTypeHeader.self)
            let exact = (0..<count).contains { index in
                let header = bytes.loadUnaligned(fromByteOffset: 12 + index * stride, as: UCKeyboardTypeHeader.self)
                return header.keyboardTypeFirst <= type && type <= header.keyboardTypeLast
            }
            return (exact, first.keyboardTypeFirst == 0)
        }
    }
}
