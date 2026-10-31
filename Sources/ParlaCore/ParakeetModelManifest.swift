import Foundation
import CryptoKit
import Darwin

/// Remote declarations only. Twelve payload SHA256 values and nine Git blob SHA1
/// values retain their distinct semantics. This is not a uniform release SHA256
/// manifest or permission to activate Install/distribute weights (G2 terms gate).
public enum ParakeetModelManifest {
    public enum HashKind: String, Sendable { case payloadSHA256, gitBlobSHA1 }
    public struct Entry: Sendable {
        public let path: String
        public let bytes: Int
        public let kind: HashKind
        public let digest: String
    }
    public static let metadataID = ParakeetWire.manifest
    public static let declaredBytes = 335_745_501
    public static let entries: [Entry] = [
        Entry(path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, kind: .payloadSHA256, digest: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        Entry(path: "Decoder.mlmodelc/coremldata.bin", bytes: 554, kind: .payloadSHA256, digest: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        Entry(path: "Decoder.mlmodelc/metadata.json", bytes: 3427, kind: .gitBlobSHA1, digest: "781350d40ed83511afc3bc31a804e6a543e69d04"),
        Entry(path: "Decoder.mlmodelc/model.mil", bytes: 13110, kind: .gitBlobSHA1, digest: "95328ba81ca8dceb16c039e62f1a7d447ede43c2"),
        Entry(path: "Decoder.mlmodelc/weights/weight.bin", bytes: 23604992, kind: .payloadSHA256, digest: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        Entry(path: "EncoderInt4.mlmodelc/analytics/coremldata.bin", bytes: 243, kind: .payloadSHA256, digest: "c296e0229ab5e32412fda92f8dcf47f0e63f0c34e343c0e2654f6c37649d2d79"),
        Entry(path: "EncoderInt4.mlmodelc/coremldata.bin", bytes: 512, kind: .payloadSHA256, digest: "3e6539cd5d5f1c3bd5a01921cd94af85eab609d49d47e1436a16faac958754d6"),
        Entry(path: "EncoderInt4.mlmodelc/metadata.json", bytes: 2954, kind: .gitBlobSHA1, digest: "3f3b994be82e93196572b4d7c2c054aefd48f1ad"),
        Entry(path: "EncoderInt4.mlmodelc/model.mil", bytes: 874445, kind: .gitBlobSHA1, digest: "bf620dded63605d789a724012251649b1a33f5a6"),
        Entry(path: "EncoderInt4.mlmodelc/weights/weight.bin", bytes: 297912320, kind: .payloadSHA256, digest: "6fcf5596562948c7482e116bdb3f364279bed970893b86737b67fe89f36367d9"),
        Entry(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243, kind: .payloadSHA256, digest: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        Entry(path: "JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521, kind: .payloadSHA256, digest: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        Entry(path: "JointDecisionv3.mlmodelc/metadata.json", bytes: 3453, kind: .gitBlobSHA1, digest: "0461ef9e55ba8e8ba0d2cb33b6e1a031b0d481d7"),
        Entry(path: "JointDecisionv3.mlmodelc/model.mil", bytes: 11775, kind: .gitBlobSHA1, digest: "0a80fde4b1ec61093a03fc0fc3431172db34a4d2"),
        Entry(path: "JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12642764, kind: .payloadSHA256, digest: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        Entry(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, kind: .payloadSHA256, digest: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        Entry(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486, kind: .payloadSHA256, digest: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        Entry(path: "Preprocessor.mlmodelc/metadata.json", bytes: 2841, kind: .gitBlobSHA1, digest: "06162c58cf2f5343a0e60f36f843bcdf3cc58527"),
        Entry(path: "Preprocessor.mlmodelc/model.mil", bytes: 28181, kind: .gitBlobSHA1, digest: "f987e2479228436c49189aa47edb376db74dcff5"),
        Entry(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491072, kind: .payloadSHA256, digest: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        Entry(path: "parakeet_vocab.json", bytes: 151122, kind: .gitBlobSHA1, digest: "c684822ec3b671ebc449c433a7012398d39b8bb0"),
    ]
    public static func verify(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw ParakeetWire.Failure.malformed }
        var root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw ParakeetWire.Failure.io }
        defer { close(root) }
        for component in directory.path.split(separator: "/") {
            guard component != ".", component != ".." else { throw ParakeetWire.Failure.malformed }
            let next = openat(root, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw ParakeetWire.Failure.io }
            close(root); root = next
        }
        var seen = Set<String>()
        try walk(root, prefix: "", seen: &seen)
        guard seen == Set(entries.map(\.path)) else { throw ParakeetWire.Failure.identity }
    }
    private static func walk(_ fd: Int32, prefix: String, seen: inout Set<String>) throws {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_mode & 0o022 == 0,
              let directory = fdopendir(dup(fd)) else { throw ParakeetWire.Failure.io }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let path = prefix + name
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw ParakeetWire.Failure.io }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                guard entries.contains(where: { $0.path.hasPrefix(path + "/") }) else { throw ParakeetWire.Failure.identity }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ParakeetWire.Failure.io }
                defer { close(child) }
                try walk(child, prefix: path + "/", seen: &seen)
            } else {
                guard metadata.st_mode & S_IFMT == S_IFREG,
                      let expected = entries.first(where: { $0.path == path }),
                      seen.insert(path).inserted else { throw ParakeetWire.Failure.identity }
                let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ParakeetWire.Failure.io }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_ino == metadata.st_ino,
                      opened.st_uid == getuid(), opened.st_nlink == 1, opened.st_mode & 0o022 == 0,
                      opened.st_size == expected.bytes else { throw ParakeetWire.Failure.identity }
                var sha256 = SHA256(); var sha1 = Insecure.SHA1()
                if expected.kind == .gitBlobSHA1 { sha1.update(data: Data("blob \(expected.bytes)\0".utf8)) }
                var bytes = 0
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(child, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw ParakeetWire.Failure.io }
                    if count == 0 { break }
                    guard count <= expected.bytes - bytes else { throw ParakeetWire.Failure.bounds }
                    bytes += count
                    let data = Data(buffer.prefix(count))
                    if expected.kind == .payloadSHA256 { sha256.update(data: data) } else { sha1.update(data: data) }
                }
                let digest = expected.kind == .payloadSHA256 ? sha256.finalize().map { String(format: "%02x", $0) }.joined() : sha1.finalize().map { String(format: "%02x", $0) }.joined()
                var after = stat()
                guard bytes == expected.bytes, digest == expected.digest, fstat(child, &after) == 0,
                      same(opened, after) else { throw ParakeetWire.Failure.identity }
            }
            errno = 0
        }
        guard errno == 0 else { throw ParakeetWire.Failure.io }
        var after = stat()
        guard fstat(fd, &after) == 0, same(before, after) else { throw ParakeetWire.Failure.identity }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
