import Foundation
import Darwin
import MachO
import whisper

/// Pure bounded LC_UUID parser; never accepts a fat image, duplicate UUID, or guessed architecture.
public enum PreparationMachO {
    public struct Image: Equatable { public let uuid: UUID; public let architecture: String }
    public static func parse(_ data: Data) throws -> Image {
        guard data.count >= 32, data.count <= 65_536 else { throw PreparationRefusal.unsupportedSelection }
        let b = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at+1]) << 8 | UInt32(b[at+2]) << 16 | UInt32(b[at+3]) << 24 }
        guard u32(0) == 0xfeedfacf else { throw PreparationRefusal.unsupportedSelection }
        let arch: String
        switch u32(4) { case 0x0100000c: arch = "arm64"; case 0x01000007: arch = "x86_64"; default: throw PreparationRefusal.unsupportedSelection }
        let count = Int(u32(16)), size = Int(u32(20))
        guard count > 0, count <= 1024, size <= 65_504, size + 32 == data.count else { throw PreparationRefusal.unsupportedSelection }
        var offset = 32, uuid: UUID?
        for _ in 0..<count {
            guard offset <= data.count - 8 else { throw PreparationRefusal.unsupportedSelection }
            let command = u32(offset), length = Int(u32(offset + 4))
            guard length >= 8, length % 8 == 0, length <= data.count - offset else { throw PreparationRefusal.unsupportedSelection }
            if command == 0x1b {
                guard length == 24, uuid == nil else { throw PreparationRefusal.unsupportedSelection }
                let x = Array(b[(offset+8)..<(offset+24)])
                guard x.contains(where: { $0 != 0 }) else { throw PreparationRefusal.unsupportedSelection }
                uuid = UUID(uuid: (x[0],x[1],x[2],x[3],x[4],x[5],x[6],x[7],x[8],x[9],x[10],x[11],x[12],x[13],x[14],x[15]))
            }
            offset += length
        }
        guard offset == data.count, let uuid else { throw PreparationRefusal.unsupportedSelection }
        return Image(uuid: uuid, architecture: arch)
    }
}
/// Loaded-image metadata only, invoked by enabled guard authorization; no binary/model disk hashing.
public enum PreparationBuildReader {
    public static func loaded() throws -> PreparationBuild {
        guard let main = _dyld_get_image_header(0) else { throw PreparationRefusal.unsupportedSelection }
        var nativeInfo = Dl_info()
        let address = unsafeBitCast(whisper_init_from_file_with_params as @convention(c) (UnsafePointer<CChar>?, whisper_context_params) -> OpaquePointer?, to: UnsafeRawPointer.self)
        guard dladdr(address, &nativeInfo) != 0, let native = nativeInfo.dli_fbase else { throw PreparationRefusal.unsupportedSelection }
        return try readImages(main: UnsafeRawPointer(main), native: UnsafeRawPointer(native))
    }
    private static func bytes(_ pointer: UnsafeRawPointer) throws -> Data {
        // dyld/dladdr return mapped image headers. Bound the region before copying load commands.
        let header = Data(bytes: pointer, count: 32), b = [UInt8](header)
        guard b.prefix(4).elementsEqual([0xcf, 0xfa, 0xed, 0xfe]) else { throw PreparationRefusal.unsupportedSelection }
        let n = Int(UInt32(b[16]) | UInt32(b[17]) << 8 | UInt32(b[18]) << 16 | UInt32(b[19]) << 24)
        let size = Int(UInt32(b[20]) | UInt32(b[21]) << 8 | UInt32(b[22]) << 16 | UInt32(b[23]) << 24)
        guard n > 0, n <= 1024, size <= 65_504 else { throw PreparationRefusal.unsupportedSelection }
        return Data(bytes: pointer, count: size + 32)
    }
    public static func readImages(main: UnsafeRawPointer, native: UnsafeRawPointer) throws -> PreparationBuild {
        let app = try PreparationMachO.parse(bytes(main)), library = try PreparationMachO.parse(bytes(native))
        guard app.architecture == library.architecture else { throw PreparationRefusal.unsupportedSelection }
        return PreparationBuild(app: app.uuid, native: library.uuid, architecture: app.architecture)
    }
}
