import Foundation

/// qtPCM16kV1 only: pure container validation and signed16LE scalar extraction.
/// No URL, media framework, playable-video assertion, legacy WAV origin or fallback.
public enum ImportedPCMMOV {
    public static let maximumBytes = 20 * 1024 * 1024
    public static let minimumFrames = 6_400
    public static let maximumFrames = 9_600_000

    public enum Failure: Error, Equatable {
        case encodedLimit, metadataLimit, boxLimit, depthLimit, rowLimit, chunkLimit
        case videoFrameLimit, workLimit, duration, malformed, unsupported, tracks, format, timing, extent, canceled
    }

    /// Facts can only be minted by this reader; matching output rate never asserts WAV origin.
    public struct Facts: Equatable, Sendable {
        public var profile: String { "qtPCM16kV1" }
        public var container: String { "QuickTime MOV" }
        public var encoding: String { "signed16LE" }
        public var rate: Int { 16_000 }
        public var channels: Int { 1 }
        public var outputRate: Int { 16_000 }
        public var outputFrames: Int { sourceFrames }
        public var clipped: Int { 0 }
        public let sourceFrames: Int
        public let audioTrackID: UInt32
        public let videoTrackID: UInt32
        public let videoFrames: Int
        public let movieTimescale: Int64
        public let movieDuration: Int64
        public let videoTimescale: Int64
        public let videoDuration: Int64
        fileprivate init(sourceFrames: Int, audioTrackID: UInt32, videoTrackID: UInt32, videoFrames: Int,
                         movieTimescale: Int64, movieDuration: Int64, videoTimescale: Int64, videoDuration: Int64) {
            self.sourceFrames = sourceFrames; self.audioTrackID = audioTrackID; self.videoTrackID = videoTrackID
            self.videoFrames = videoFrames; self.movieTimescale = movieTimescale; self.movieDuration = movieDuration
            self.videoTimescale = videoTimescale; self.videoDuration = videoDuration
        }
    }

    public struct Inspection: Sendable {
        fileprivate let source: Data
        fileprivate let audioChunks: [Range<Int>]
        public let facts: Facts
        /// Exact owned, zero-origin source value; ordinary caller mutations use Data copy-on-write.
        public var sourceBytes: Data { source }
        public var audioChunkCount: Int { audioChunks.count }
        fileprivate init(source: Data, audioChunks: [Range<Int>], facts: Facts) {
            self.source = source; self.audioChunks = audioChunks; self.facts = facts
        }
        /// No replacement bytes parameter: private extents always index their own immutable snapshot.
        public func decode(canceled: () -> Bool = { false }) throws -> Decoded {
            try ImportedPCMMOV.check(canceled)
            return try source.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                var samples: [Float] = []
                samples.reserveCapacity(facts.sourceFrames)
                try ImportedPCMMOV.check(canceled)
                for range in audioChunks {
                    try ImportedPCMMOV.check(canceled)
                    var p = range.lowerBound
                    while p < range.upperBound {
                        try ImportedPCMMOV.check(canceled)
                        // Validated chunk lengths are even; never allocate/copy individual samples.
                        let end = p + min(8_192, range.upperBound - p)
                        while p < end {
                            let word = UInt16(b[p]) | UInt16(b[p + 1]) << 8
                            samples.append(Float(Int16(bitPattern: word)) / 32_768)
                            p += 2
                        }
                    }
                }
                guard samples.count == facts.sourceFrames else { throw Failure.malformed }
                try ImportedPCMMOV.check(canceled)
                return Decoded(inspection: self, samples: samples)
            }
        }
    }

    public struct Decoded: Sendable {
        public let inspection: Inspection
        public let samples: [Float]
        public var sourceBytes: Data { inspection.sourceBytes }
        public var facts: Facts { inspection.facts }
        fileprivate init(inspection: Inspection, samples: [Float]) {
            self.inspection = inspection; self.samples = samples
        }
    }

    public static func decode(_ bytes: Data, canceled: () -> Bool = { false }) throws -> Decoded {
        try inspect(bytes, canceled: canceled).decode(canceled: canceled)
    }

    public static func inspect(_ bytes: Data, canceled: () -> Bool = { false }) throws -> Inspection {
        try check(canceled)
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.encodedLimit }
        // Always deep-copy, including zero-origin Data(bytesNoCopy:) with external mutable aliases.
        // The caller must not concurrently mutate input memory while this bounded copy occurs.
        let source = try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress else { throw Failure.malformed }
            return Data(bytes: base, count: raw.count)
        }
        try check(canceled)
        return try source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try withoutActuallyEscaping(canceled) { cancellation in
                try Parser(raw, canceled: cancellation).inspect(source: source)
            }
        }
    }

    private static func check(_ canceled: () -> Bool) throws {
        if canceled() { throw Failure.canceled }
    }

    private struct Box { let type: String; let body: Range<Int> }
    private struct Table { let start: Int; let count: Int }
    private struct Track {
        let id: UInt32
        let audio: Bool
        let count: Int
        let scale: Int64
        let duration: Int64
        let chunks: [Range<Int>]
    }

    private final class Parser {
        let b: UnsafeRawBufferPointer
        let canceled: () -> Bool
        var boxesRead = 0, rowsRead = 0, chunksRead = 0, work = 0
        var media = 0..<0
        init(_ b: UnsafeRawBufferPointer, canceled: @escaping () -> Bool) {
            self.b = b; self.canceled = canceled
        }
        func check() throws { try ImportedPCMMOV.check(canceled) }
        func charge(_ n: Int = 1) throws {
            try check()
            guard n >= 0, n <= 131_072 - work else { throw Failure.workLimit }
            work += n
        }
        func rows(_ n: Int) throws {
            guard n >= 0, n <= 32_768 - rowsRead else { throw Failure.rowLimit }
            try charge(n); rowsRead += n
        }
        func need(_ p: Int, _ n: Int, in r: Range<Int>) throws {
            guard p >= r.lowerBound, p <= r.upperBound, n >= 0, n <= r.upperBound - p else {
                throw Failure.malformed
            }
        }
        func u16(_ p: Int) -> Int { Int(b[p]) << 8 | Int(b[p + 1]) }
        func u32(_ p: Int) -> UInt32 {
            UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
        }
        func tag(_ p: Int) -> String { String(decoding: b[p..<(p + 4)], as: UTF8.self) }
        func zero(_ r: Range<Int>) -> Bool { r.allSatisfy { b[$0] == 0 } }
        func add(_ a: Int64, _ c: Int64) throws -> Int64 {
            let (v, overflow) = a.addingReportingOverflow(c)
            guard a >= 0, c >= 0, !overflow, v >= 0 else { throw Failure.malformed }
            return v
        }
        func multiply(_ a: Int64, _ c: Int64) throws -> Int64 {
            let (v, overflow) = a.multipliedReportingOverflow(by: c)
            guard a >= 0, c >= 0, !overflow, v >= 0 else { throw Failure.malformed }
            return v
        }
        func boundedInt(_ value: Int64, maximum: Int, failure: Failure) throws -> Int {
            guard value >= 0, value <= Int64(maximum), let result = Int(exactly: value) else { throw failure }
            return result
        }
        func exactScale(_ ticks: Int64, from: Int64, to: Int64) throws -> Int64 {
            guard ticks >= 0, from > 0, to > 0 else { throw Failure.timing }
            var a = from, c = to
            while c != 0 { try check(); let remainder = a % c; a = c; c = remainder }
            let divisor = from / a
            guard ticks % divisor == 0 else { throw Failure.timing }
            return try multiply(ticks / divisor, to / a)
        }

        func boxes(_ r: Range<Int>, depth: Int) throws -> [Box] {
            try check()
            guard depth <= 12 else { throw Failure.depthLimit }
            var result: [Box] = [], p = r.lowerBound
            while p < r.upperBound {
                try check()
                guard boxesRead < 4_096 else { throw Failure.boxLimit }
                try charge()
                try need(p, 8, in: r)
                let size = Int64(u32(p)), type = tag(p + 4)
                guard size != 0, size != 1, type != "uuid" else { throw Failure.unsupported }
                let length = try boundedInt(size, maximum: r.upperBound - p, failure: .malformed)
                guard length >= 8 else { throw Failure.malformed }
                let end = p + length
                boxesRead += 1
                result.append(Box(type: type, body: (p + 8)..<end)); p = end
            }
            return result
        }
        func children(_ box: Box, depth: Int, required: Set<String>, optional: Set<String> = []) throws -> [String: Box] {
            let list = try boxes(box.body, depth: depth)
            var result: [String: Box] = [:]
            for child in list {
                try charge()
                guard required.contains(child.type) || optional.contains(child.type) else { throw Failure.unsupported }
                guard result[child.type] == nil else { throw Failure.malformed }
                result[child.type] = child
            }
            guard required.isSubset(of: Set(result.keys)) else { throw Failure.malformed }
            return result
        }
        func only(_ c: [String: Box], _ name: String) throws -> Box {
            guard let box = c[name] else { throw Failure.malformed }; return box
        }
        func full(_ box: Box, length: Int? = nil, flags: UInt32 = 0) throws -> Int {
            let p = box.body.lowerBound
            try need(p, 4, in: box.body)
            guard u32(p) == flags else { throw Failure.unsupported }
            if let length, box.body.count != length { throw Failure.malformed }
            return p
        }
        func table(_ box: Box, width: Int, maximum: Int = 32_768, failure: Failure = .rowLimit) throws -> Table {
            let p = try full(box)
            try need(p, 8, in: box.body)
            let count = try boundedInt(Int64(u32(p + 4)), maximum: maximum, failure: failure)
            guard try multiply(Int64(count), Int64(width)) == Int64(box.body.count - 8) else {
                throw Failure.malformed
            }
            try rows(count)
            return Table(start: p + 8, count: count)
        }

        func inspect(source: Data) throws -> Inspection {
            let top = try boxes(0..<b.count, depth: 1)
            var brand: Box?, movie: Box?, payload: Box?
            for box in top {
                try charge()
                switch box.type {
                case "ftyp": guard brand == nil else { throw Failure.malformed }; brand = box
                case "moov": guard movie == nil else { throw Failure.malformed }; movie = box
                case "mdat": guard payload == nil, !box.body.isEmpty else { throw Failure.malformed }; payload = box
                case "free", "skip": break
                default: throw Failure.unsupported
                }
            }
            guard let brand, let movie, let payload else { throw Failure.malformed }
            guard b.count - payload.body.count <= 2 * 1024 * 1024 else { throw Failure.metadataLimit }
            media = payload.body
            try brands(brand)
            let movieChildren = try boxes(movie.body, depth: 2)
            var header: Box?, tracks: [Box] = []
            for child in movieChildren {
                try charge()
                switch child.type {
                case "mvhd": guard header == nil else { throw Failure.tracks }; header = child
                case "trak": guard tracks.count < 2 else { throw Failure.tracks }; tracks.append(child)
                default: throw Failure.unsupported
                }
            }
            guard let header, tracks.count == 2 else { throw Failure.tracks }
            let (scale, duration) = try movieHeader(header)
            let first = try track(tracks[0], movieScale: scale, movieDuration: duration)
            let second = try track(tracks[1], movieScale: scale, movieDuration: duration)
            guard first.id != second.id, first.audio != second.audio else { throw Failure.tracks }
            let audio = first.audio ? first : second, video = first.audio ? second : first
            guard try exactScale(Int64(audio.count), from: 16_000, to: scale) == duration else { throw Failure.timing }
            try disjoint(audio.chunks, video.chunks)
            try check()
            return Inspection(source: source, audioChunks: audio.chunks,
                              facts: Facts(sourceFrames: audio.count, audioTrackID: audio.id, videoTrackID: video.id,
                                           videoFrames: video.count, movieTimescale: scale, movieDuration: duration,
                                           videoTimescale: video.scale, videoDuration: video.duration))
        }
        func brands(_ box: Box) throws {
            let p = box.body.lowerBound
            guard box.body.count >= 8, (box.body.count - 8) % 4 == 0 else { throw Failure.malformed }
            guard tag(p) == "qt  " else { throw Failure.unsupported }
            let count = (box.body.count - 8) / 4
            try charge(count)
            for i in 0..<count {
                try check()
                guard tag(p + 8 + i * 4) == "qt  " else { throw Failure.unsupported }
            }
        }
        func identityMatrix(_ p: Int) -> Bool {
            let words: [UInt32] = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000]
            return words.indices.allSatisfy { u32(p + $0 * 4) == words[$0] }
        }
        func movieHeader(_ box: Box) throws -> (Int64, Int64) {
            let p = try full(box, length: 100)
            let scale = Int64(u32(p + 12)), duration = Int64(u32(p + 16))
            guard scale > 0, duration > 0, u32(p + 20) == 0x10000, u16(p + 24) == 0x100,
                  zero((p + 26)..<(p + 36)), identityMatrix(p + 36), zero((p + 72)..<(p + 96)),
                  u32(p + 96) > 0 else { throw Failure.unsupported }
            return (scale, duration)
        }
        func track(_ box: Box, movieScale: Int64, movieDuration: Int64) throws -> Track {
            let c = try children(box, depth: 3, required: ["tkhd", "mdia"], optional: ["edts"])
            let t = try full(try only(c, "tkhd"), length: 84, flags: 3)
            let id = u32(t + 12)
            guard id > 0, u32(t + 16) == 0, Int64(u32(t + 20)) == movieDuration,
                  zero((t + 24)..<(t + 36)), u16(t + 38) == 0, identityMatrix(t + 40) else { throw Failure.tracks }
            let m = try children(try only(c, "mdia"), depth: 4, required: ["mdhd", "hdlr", "minf"])
            let d = try full(try only(m, "mdhd"), length: 24)
            let scale = Int64(u32(d + 12)), duration = Int64(u32(d + 16))
            guard scale > 0, duration > 0, u16(d + 22) == 0 else { throw Failure.timing }
            let handler = try only(m, "hdlr"), h = try full(handler)
            try need(h, 24, in: handler.body)
            guard u32(h + 4) == 0, zero((h + 12)..<(h + 24)) else { throw Failure.unsupported }
            let kind = tag(h + 8)
            guard kind == "soun" || kind == "vide" else { throw Failure.tracks }
            let audio = kind == "soun"
            guard audio ? (u16(t + 36) == 0x100 && u32(t + 76) == 0 && u32(t + 80) == 0)
                        : (u16(t + 36) == 0 && u32(t + 76) > 0 && u32(t + 80) > 0) else { throw Failure.format }
            guard !audio || scale == 16_000 else { throw Failure.timing }
            guard try exactScale(duration, from: scale, to: movieScale) == movieDuration else { throw Failure.timing }
            if let edit = c["edts"] { try identityEdit(edit, movieDuration: movieDuration) }
            let minf = try children(try only(m, "minf"), depth: 5,
                                    required: [audio ? "smhd" : "vmhd", "dinf", "stbl"])
            if audio {
                let p = try full(try only(minf, "smhd"), length: 8)
                guard u32(p + 4) == 0 else { throw Failure.unsupported }
            } else {
                let p = try full(try only(minf, "vmhd"), length: 12, flags: 1)
                guard zero((p + 4)..<(p + 12)) else { throw Failure.unsupported }
            }
            try references(try only(minf, "dinf"))
            let stbl = try children(try only(minf, "stbl"), depth: 6,
                                    required: ["stsd", "stts", "stsz", "stsc", "stco"], optional: audio ? [] : ["stss"])
            try description(try only(stbl, "stsd"), audio: audio)
            let sizeBox = try only(stbl, "stsz"), s = try full(sizeBox)
            try need(s, 12, in: sizeBox.body)
            let fixed = Int64(u32(s + 4))
            let count = try boundedInt(Int64(u32(s + 8)), maximum: audio ? ImportedPCMMOV.maximumFrames : 32_768,
                                       failure: audio ? .duration : .videoFrameLimit)
            guard count > 0 else { throw Failure.duration }
            if audio {
                guard count >= ImportedPCMMOV.minimumFrames else { throw Failure.duration }
                guard fixed == 2 else { throw Failure.format }
            }
            let explicit = fixed == 0 ? count : 0
            guard try multiply(Int64(explicit), 4) == Int64(sizeBox.body.count - 12) else { throw Failure.malformed }
            if explicit > 0 { try rows(explicit) }
            if fixed > 0 {
                guard try multiply(fixed, Int64(count)) <= Int64(media.count) else { throw Failure.extent }
            }
            guard !audio || duration == Int64(count) else { throw Failure.timing }
            try timing(try only(stbl, "stts"), count: count, duration: duration, audio: audio)
            let chunks = try extents(stbl, sizes: s + 12, fixed: fixed, count: count, audio: audio)
            if let sync = stbl["stss"] {
                let entries = try table(sync, width: 4)
                guard entries.count > 0 else { throw Failure.malformed }
                var last: UInt32 = 0
                for i in 0..<entries.count {
                    try check()
                    let n = u32(entries.start + i * 4)
                    guard n > last, Int64(n) <= Int64(count) else { throw Failure.malformed }; last = n
                }
            }
            return Track(id: id, audio: audio, count: count, scale: scale, duration: duration, chunks: chunks)
        }
        func identityEdit(_ box: Box, movieDuration: Int64) throws {
            let c = try children(box, depth: 4, required: ["elst"])
            let p = try full(try only(c, "elst"), length: 20)
            guard u32(p + 4) == 1, Int64(u32(p + 8)) == movieDuration,
                  u32(p + 12) == 0, u32(p + 16) == 0x10000 else { throw Failure.timing }
            try rows(1)
        }
        func references(_ box: Box) throws {
            let c = try children(box, depth: 6, required: ["dref"]), dref = try only(c, "dref")
            let p = try full(dref)
            try need(p, 8, in: dref.body)
            guard u32(p + 4) == 1 else { throw Failure.unsupported }
            try rows(1)
            let entries = try boxes((p + 8)..<dref.body.upperBound, depth: 7)
            guard entries.count == 1, entries[0].type == "url " else { throw Failure.unsupported }
            _ = try full(entries[0], length: 4, flags: 1)
        }
        func description(_ box: Box, audio: Bool) throws {
            let p = try full(box)
            try need(p, 8, in: box.body)
            guard u32(p + 4) == 1 else { throw Failure.unsupported }
            try rows(1)
            let entries = try boxes((p + 8)..<box.body.upperBound, depth: 7)
            guard entries.count == 1 else { throw Failure.malformed }
            let entry = entries[0], e = entry.body.lowerBound
            try need(e, audio ? 28 : 78, in: entry.body)
            guard zero(e..<(e + 6)), u16(e + 6) == 1 else { throw Failure.unsupported }
            if audio {
                guard entry.type == "sowt", entry.body.count == 28, zero((e + 8)..<(e + 16)),
                      u16(e + 16) == 1, u16(e + 18) == 16, u32(e + 20) == 0,
                      u32(e + 24) == 0x3e800000 else { throw Failure.format }
            } else {
                guard entry.type == "avc1", u16(e + 24) > 0, u16(e + 26) > 0 else { throw Failure.format }
                // Remaining fixed visual fields and bounded tail are opaque ONLY to this pure reader.
                // They are neither parsed as child boxes nor certified as a playable video bitstream.
            }
        }
        func timing(_ box: Box, count: Int, duration: Int64, audio: Bool) throws {
            let entries = try table(box, width: 8)
            guard entries.count > 0, !audio || entries.count == 1 else { throw Failure.timing }
            var samples: Int64 = 0, ticks: Int64 = 0
            for i in 0..<entries.count {
                try check()
                let p = entries.start + i * 8, n = Int64(u32(p)), delta = Int64(u32(p + 4))
                guard n > 0, delta > 0, !audio || delta == 1 else { throw Failure.timing }
                samples = try add(samples, n)
                guard samples <= Int64(count) else { throw Failure.timing }
                ticks = try add(ticks, try multiply(n, delta))
            }
            guard samples == Int64(count), ticks == duration else { throw Failure.timing }
        }
        func extents(_ c: [String: Box], sizes: Int, fixed: Int64, count: Int, audio: Bool) throws -> [Range<Int>] {
            let offsets = try table(try only(c, "stco"), width: 4, maximum: 4_096, failure: .chunkLimit)
            guard offsets.count > 0, offsets.count <= 4_096 - chunksRead else { throw Failure.chunkLimit }
            chunksRead += offsets.count
            let runs = try table(try only(c, "stsc"), width: 12, maximum: 4_096, failure: .chunkLimit)
            guard runs.count > 0 else { throw Failure.malformed }
            var declared: Int64 = 0
            for i in 0..<runs.count {
                try check()
                let p = runs.start + i * 12, first = Int64(u32(p)), perChunk = Int64(u32(p + 4))
                let next = i + 1 < runs.count ? Int64(u32(p + 12)) : Int64(offsets.count + 1)
                guard (i != 0 || first == 1), first > 0, first <= Int64(offsets.count), next > first,
                      next <= Int64(offsets.count + 1), perChunk > 0, u32(p + 8) == 1 else { throw Failure.malformed }
                declared = try add(declared, try multiply(next - first, perChunk))
                guard declared <= Int64(count) else { throw Failure.malformed }
            }
            guard declared == Int64(count) else { throw Failure.malformed }
            try charge(offsets.count) // chunk construction, separately from explicit stco rows
            var result: [Range<Int>] = []; result.reserveCapacity(offsets.count)
            var run = 0, sample = 0, previousEnd = 0
            for chunk in 0..<offsets.count {
                try check()
                if run + 1 < runs.count, Int64(u32(runs.start + (run + 1) * 12)) == Int64(chunk + 1) { run += 1 }
                let perChunk = try boundedInt(Int64(u32(runs.start + run * 12 + 4)), maximum: count - sample, failure: .malformed)
                let offset = try boundedInt(Int64(u32(offsets.start + chunk * 4)), maximum: b.count, failure: .extent)
                guard offset >= media.lowerBound, offset < media.upperBound else { throw Failure.extent }
                var length: Int64 = 0
                if fixed > 0 { length = try multiply(fixed, Int64(perChunk)) }
                else {
                    for i in sample..<(sample + perChunk) {
                        try check() // each explicit video size row, already charged before this walk
                        let size = Int64(u32(sizes + i * 4))
                        guard size > 0 else { throw Failure.extent }
                        length = try add(length, size)
                        guard length <= Int64(media.upperBound - offset) else { throw Failure.extent }
                    }
                }
                let bytes = try boundedInt(length, maximum: media.upperBound - offset, failure: .extent)
                guard bytes > 0, !audio || offset >= previousEnd else { throw Failure.extent }
                let end = offset + bytes
                result.append(offset..<end); previousEnd = end; sample += perChunk
            }
            guard sample == count else { throw Failure.malformed }
            return result
        }
        /// Deterministic bottom-up merge: charges every emitted range and every comparison.
        /// Only this temporary list is reordered; audio chunks remain in media/table order.
        func disjoint(_ audio: [Range<Int>], _ video: [Range<Int>]) throws {
            var source = audio + video
            var scratch = [Range<Int>](repeating: 0..<0, count: source.count), width = 1
            while width < source.count {
                var start = 0
                while start < source.count {
                    let middle = min(start + width, source.count), end = min(middle + width, source.count)
                    var left = start, right = middle
                    for output in start..<end {
                        try charge()
                        let takeLeft: Bool
                        if left == middle { takeLeft = false }
                        else if right == end { takeLeft = true }
                        else { try charge(); takeLeft = source[left].lowerBound <= source[right].lowerBound }
                        if takeLeft { scratch[output] = source[left]; left += 1 }
                        else { scratch[output] = source[right]; right += 1 }
                    }
                    start = end
                }
                swap(&source, &scratch); width *= 2 // <=4096 chunk bound precedes this allocation/walk
            }
            var end = media.lowerBound
            for range in source {
                try charge()
                guard range.lowerBound >= end else { throw Failure.extent }; end = range.upperBound
            }
        }
    }
}
