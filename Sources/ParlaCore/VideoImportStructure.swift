import Foundation

/// Pure, closed structural projection. A successful inspection never authorizes native decoding.
public enum VideoImportStructure {
    public enum Failure: Error, Equatable {
        case encodedLimit, boxLimit, depthLimit, metadataLimit, workLimit, sampleLimit, packetLimit
        case malformed, unsupported, tracks, format, timing, extent
    }

    public enum Container: Equatable, Sendable { case mp4, quickTime }
    public enum NativeEligibility: Equatable, Sendable {
        /// Neither complete encoder-delay evidence nor native trim equivalence is established.
        case notAdmittedAACDelayAndNativeTrimUnproven
    }

    public struct Interval: Equatable, Sendable {
        public let start: Int64
        public let duration: Int64
        public let timescale: Int64
        fileprivate init(start: Int64, duration: Int64, timescale: Int64) {
            self.start = start; self.duration = duration; self.timescale = timescale
        }
    }

    public struct Audio: Equatable, Sendable {
        public let trackID: UInt32
        public let rate: Int
        public let channels: Int
        public let packetCount: Int
        public let packetDomainFrames: Int64
        /// Container-declared edit arithmetic, NOT verified encoder priming or decoded PCM counts.
        public let declaredLeadingFrames: Int64
        public let declaredTrailingFrames: Int64
        public let declaredPresentationFrames: Int64
        public let mediaInterval: Interval
        /// Ordered zero-based packet ranges indexing sourceBytes; no payload or waveform validation.
        public let packets: [Range<Int>]
        fileprivate init(trackID: UInt32, rate: Int, channels: Int, packetCount: Int, packetDomainFrames: Int64,
                         declaredLeadingFrames: Int64, declaredTrailingFrames: Int64, declaredPresentationFrames: Int64,
                         mediaInterval: Interval, packets: [Range<Int>]) {
            self.trackID = trackID; self.rate = rate; self.channels = channels; self.packetCount = packetCount
            self.packetDomainFrames = packetDomainFrames; self.declaredLeadingFrames = declaredLeadingFrames
            self.declaredTrailingFrames = declaredTrailingFrames; self.declaredPresentationFrames = declaredPresentationFrames
            self.mediaInterval = mediaInterval; self.packets = packets
        }
    }

    public struct Video: Equatable, Sendable {
        public let trackID: UInt32
        public let mediaInterval: Interval
        /// Zero-based file ranges indexing Projection.sourceBytes.
        public let samples: [Range<Int>]
        fileprivate init(trackID: UInt32, mediaInterval: Interval, samples: [Range<Int>]) {
            self.trackID = trackID; self.mediaInterval = mediaInterval; self.samples = samples
        }
    }

    public struct Projection: Equatable, Sendable {
        /// Exact value-semantic bytes, normalized to zero-origin indices for every exposed range.
        public let sourceBytes: Data
        public let container: Container
        public let mediaData: [Range<Int>]
        public let audio: Audio
        public let video: Video
        public let nativeEligibility: NativeEligibility
        fileprivate init(sourceBytes: Data, container: Container, mediaData: [Range<Int>], audio: Audio,
                         video: Video, nativeEligibility: NativeEligibility) {
            self.sourceBytes = sourceBytes; self.container = container; self.mediaData = mediaData
            self.audio = audio; self.video = video; self.nativeEligibility = nativeEligibility
        }
    }

    public static func inspect(_ bytes: Data) throws -> Projection {
        guard !bytes.isEmpty, bytes.count <= 20 * 1024 * 1024 else { throw Failure.encodedLimit }
        return try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source: Data
            if bytes.startIndex == 0 {
                source = bytes
            } else {
                guard let base = raw.baseAddress else { throw Failure.malformed }
                source = Data(bytes: base, count: raw.count)
            }
            return try Parser(raw).inspect(source: source)
        }
    }

    private struct Box {
        let type: String
        let body: Range<Int>
    }

    private struct Table {
        let start: Int
        let count: Int
    }

    private struct Track {
        let id: UInt32
        let audio: Bool
        let rate: Int
        let channels: Int
        let scale: Int64
        let duration: Int64
        let presentation: Int64
        let leading: Int64
        let trailing: Int64
        let samples: [Range<Int>]
    }

    private final class Parser {
        let b: UnsafeRawBufferPointer
        var boxCount = 0
        var work = 0
        var sampleCount = 0
        var mdats: [Range<Int>] = []

        init(_ bytes: UnsafeRawBufferPointer) { b = bytes }

        func need(_ p: Int, _ n: Int, in r: Range<Int>) throws {
            guard p >= r.lowerBound, p <= r.upperBound, n >= 0, n <= r.upperBound - p else {
                throw Failure.malformed
            }
        }
        func u16(_ p: Int) -> Int { Int(b[p]) << 8 | Int(b[p + 1]) }
        func u32(_ p: Int) -> UInt32 {
            UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
        }
        func u64(_ p: Int) -> UInt64 { UInt64(u32(p)) << 32 | UInt64(u32(p + 4)) }
        func tag(_ p: Int) -> String { String(decoding: b[p..<(p + 4)], as: UTF8.self) }
        func zero(_ r: Range<Int>) -> Bool { r.allSatisfy { b[$0] == 0 } }
        func add(_ a: Int64, _ c: Int64) throws -> Int64 {
            let (v, overflow) = a.addingReportingOverflow(c)
            guard !overflow, v >= 0 else { throw Failure.malformed }; return v
        }
        func multiply(_ a: Int64, _ c: Int64) throws -> Int64 {
            let (v, overflow) = a.multipliedReportingOverflow(by: c)
            guard !overflow, v >= 0 else { throw Failure.malformed }; return v
        }
        func charge(_ n: Int) throws {
            guard n >= 0, n <= 131_072 - work else { throw Failure.workLimit }; work += n
        }
        func exactScale(_ ticks: Int64, from: Int64, to: Int64) throws -> Int64 {
            guard from > 0, to > 0 else { throw Failure.timing }
            // Reduce before multiplication; no floating point tolerance or rounded edit mapping.
            var a = from, c = to
            while c != 0 { let remainder = a % c; a = c; c = remainder }
            let divisor = from / a
            guard ticks >= 0, ticks % divisor == 0 else { throw Failure.timing }
            return try multiply(ticks / divisor, to / a)
        }

        func boxes(_ r: Range<Int>, depth: Int) throws -> [Box] {
            guard depth <= 12 else { throw Failure.depthLimit }
            var result: [Box] = [], p = r.lowerBound
            while p < r.upperBound {
                guard boxCount < 4096 else { throw Failure.boxLimit }
                try need(p, 8, in: r)
                var size = UInt64(u32(p)), header = 8
                if size == 1 { try need(p, 16, in: r); size = u64(p + 8); header = 16 }
                guard size >= UInt64(header), size <= UInt64(r.upperBound - p) else { throw Failure.malformed }
                // Size zero/to-EOF and uuid extension headers have no admitted interpretation.
                let type = tag(p + 4)
                guard type != "uuid" else { throw Failure.unsupported }
                let end = p + Int(size)
                boxCount += 1
                result.append(Box(type: type, body: (p + header)..<end)); p = end
            }
            return result
        }

        func children(_ box: Box, depth: Int, required: Set<String>, optional: Set<String> = []) throws -> [String: Box] {
            let list = try boxes(box.body, depth: depth)
            var result: [String: Box] = [:]
            for child in list {
                guard required.contains(child.type) || optional.contains(child.type) else { throw Failure.unsupported }
                guard result[child.type] == nil else { throw Failure.malformed }
                result[child.type] = child
            }
            guard required.isSubset(of: Set(result.keys)) else { throw Failure.malformed }
            return result
        }

        func only(_ children: [String: Box], _ name: String) throws -> Box {
            guard let box = children[name] else { throw Failure.malformed }; return box
        }
        func full(_ box: Box, length: Int? = nil, flags: UInt32 = 0) throws -> Int {
            try need(box.body.lowerBound, 4, in: box.body)
            guard u32(box.body.lowerBound) == flags else { throw Failure.unsupported }
            if let length, box.body.count != length { throw Failure.malformed }
            return box.body.lowerBound
        }
        func table(_ box: Box, width: Int) throws -> Table {
            let p = try full(box)
            try need(p, 8, in: box.body)
            let count = Int(u32(p + 4))
            // Exact raw length and budget precede all row loops and allocations.
            guard Int64(box.body.count - 8) == (try multiply(Int64(count), Int64(width))) else { throw Failure.malformed }
            try charge(count)
            return Table(start: p + 8, count: count)
        }

        func inspect(source: Data) throws -> Projection {
            let top = try boxes(0..<b.count, depth: 1)
            var ftyp: Box?, moov: Box?, payloadBytes = 0
            for box in top {
                switch box.type {
                case "ftyp": guard ftyp == nil else { throw Failure.malformed }; ftyp = box
                case "moov": guard moov == nil else { throw Failure.malformed }; moov = box
                case "mdat":
                    guard !box.body.isEmpty else { throw Failure.malformed }
                    mdats.append(box.body); payloadBytes += box.body.count
                case "free", "skip": break // opaque padding; never traversed or used as a reference
                default: throw Failure.unsupported
                }
            }
            guard b.count - payloadBytes <= 2 * 1024 * 1024 else { throw Failure.metadataLimit }
            guard let ftyp, let moov, !mdats.isEmpty else { throw Failure.malformed }
            let container = try brand(ftyp)
            let movie = try boxes(moov.body, depth: 2)
            let headers = movie.filter { $0.type == "mvhd" }, tracks = movie.filter { $0.type == "trak" }
            guard movie.allSatisfy({ $0.type == "mvhd" || $0.type == "trak" }) else { throw Failure.unsupported }
            guard headers.count == 1, tracks.count == 2 else { throw Failure.tracks }
            let (movieScale, movieDuration) = try movieHeader(headers[0])
            let first = try track(tracks[0], movieScale: movieScale, movieDuration: movieDuration)
            let second = try track(tracks[1], movieScale: movieScale, movieDuration: movieDuration)
            guard first.id != second.id, first.audio != second.audio else { throw Failure.tracks }
            let audio = first.audio ? first : second, video = first.audio ? second : first
            // Cross-track and within-track alias/reuse are equally forbidden, including video bytes.
            let extents = (audio.samples + video.samples).sorted { $0.lowerBound < $1.lowerBound }
            var end = 0
            for extent in extents {
                guard extent.lowerBound >= end else { throw Failure.extent }; end = extent.upperBound
            }
            let facts = Audio(trackID: audio.id, rate: audio.rate, channels: audio.channels,
                              packetCount: audio.samples.count, packetDomainFrames: audio.duration,
                              declaredLeadingFrames: audio.leading, declaredTrailingFrames: audio.trailing,
                              declaredPresentationFrames: audio.presentation,
                              mediaInterval: Interval(start: audio.leading, duration: audio.presentation, timescale: audio.scale),
                              packets: audio.samples)
            return Projection(sourceBytes: source, container: container, mediaData: mdats, audio: facts,
                              video: Video(trackID: video.id, mediaInterval: Interval(start: 0, duration: video.duration,
                                                                                    timescale: video.scale), samples: video.samples),
                              nativeEligibility: .notAdmittedAACDelayAndNativeTrimUnproven)
        }

        func brand(_ box: Box) throws -> Container {
            let p = box.body.lowerBound
            guard box.body.count >= 8, (box.body.count - 8) % 4 == 0 else { throw Failure.malformed }
            let major = tag(p), mp4: Set<String> = ["isom", "iso2", "mp41", "mp42"]
            guard major == "qt  " || mp4.contains(major) else { throw Failure.unsupported }
            for q in stride(from: p + 8, to: box.body.upperBound, by: 4) {
                let compatible = tag(q)
                guard major == "qt  " ? compatible == "qt  " : mp4.contains(compatible) else { throw Failure.unsupported }
            }
            return major == "qt  " ? .quickTime : .mp4
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
            let tkhd = try only(c, "tkhd"), t = try full(tkhd, length: 84, flags: 3)
            let id = u32(t + 12)
            guard id > 0, u32(t + 16) == 0, Int64(u32(t + 20)) == movieDuration,
                  zero((t + 24)..<(t + 36)), u16(t + 38) == 0, identityMatrix(t + 40) else { throw Failure.tracks }
            let m = try children(try only(c, "mdia"), depth: 4, required: ["mdhd", "hdlr", "minf"])
            let mdhd = try only(m, "mdhd"), d = try full(mdhd, length: 24)
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
            let minf = try children(try only(m, "minf"), depth: 5,
                                    required: [audio ? "smhd" : "vmhd", "dinf", "stbl"])
            if audio {
                let smhd = try only(minf, "smhd"), p = try full(smhd, length: 8)
                guard u32(p + 4) == 0 else { throw Failure.unsupported }
            } else {
                let vmhd = try only(minf, "vmhd"), p = try full(vmhd, length: 12, flags: 1)
                guard zero((p + 4)..<(p + 12)) else { throw Failure.unsupported }
            }
            try references(try only(minf, "dinf"))
            let stbl = try children(try only(minf, "stbl"), depth: 6,
                                    required: ["stsd", "stts", "stsc", "stsz"], optional: ["stco", "co64", "stss"])
            let (rate, channels) = try description(try only(stbl, "stsd"), audio: audio)
            guard !audio || scale == Int64(rate) else { throw Failure.timing }
            if !audio {
                guard c["edts"] == nil, try exactScale(duration, from: scale, to: movieScale) == movieDuration else {
                    throw Failure.timing
                }
            }
            let sizes = try only(stbl, "stsz"), s = try full(sizes)
            try need(s, 12, in: sizes.body)
            let fixed = Int(u32(s + 4)), count = Int(u32(s + 8))
            guard count > 0, count <= 131_072 - sampleCount else { throw Failure.sampleLimit }
            guard !audio || count <= 32_768 else { throw Failure.packetLimit }
            guard sizes.body.count - 12 == (fixed == 0 ? count * 4 : 0) else { throw Failure.malformed }
            if fixed == 0 { try charge(count) }
            sampleCount += count
            try timing(try only(stbl, "stts"), count: count, duration: duration, audio: audio)
            let ranges = try extents(stbl, sizes: s, fixed: fixed, count: count)
            if let sync = stbl["stss"] {
                guard !audio else { throw Failure.unsupported }
                let entries = try table(sync, width: 4)
                guard entries.count > 0 else { throw Failure.malformed }
                var last: UInt32 = 0
                for i in 0..<entries.count {
                    let n = u32(entries.start + i * 4)
                    guard n > last, Int(n) <= count else { throw Failure.malformed }; last = n
                }
            }
            var leading: Int64 = 0, trailing: Int64 = 0, presentation = duration
            if audio {
                // An explicit single edit is required even for a zero declared trim. Missing delay
                // structures are never converted into an assertion that priming is zero.
                guard let edit = c["edts"] else { throw Failure.timing }
                let edits = try children(edit, depth: 4, required: ["elst"])
                let elst = try only(edits, "elst"), e = try full(elst, length: 20)
                guard u32(e + 4) == 1, Int64(u32(e + 8)) == movieDuration,
                      u32(e + 12) <= 16_384, u32(e + 16) == 0x10000 else { throw Failure.timing }
                leading = Int64(u32(e + 12))
                presentation = try exactScale(movieDuration, from: movieScale, to: scale)
                let used = try add(leading, presentation)
                guard used <= duration else { throw Failure.timing }; trailing = duration - used
                guard trailing <= 16_384, try multiply(presentation, 5) >= Int64(rate) * 2,
                      presentation <= Int64(rate) * 600 else { throw Failure.timing }
            }
            return Track(id: id, audio: audio, rate: rate, channels: channels, scale: scale, duration: duration,
                         presentation: presentation, leading: leading, trailing: trailing, samples: ranges)
        }

        func references(_ box: Box) throws {
            let c = try children(box, depth: 6, required: ["dref"]), dref = try only(c, "dref")
            let p = try full(dref)
            try need(p, 8, in: dref.body)
            guard u32(p + 4) == 1 else { throw Failure.unsupported }
            let entries = try boxes((p + 8)..<dref.body.upperBound, depth: 7)
            guard entries.count == 1, entries[0].type == "url " else { throw Failure.unsupported }
            _ = try full(entries[0], length: 4, flags: 1) // self-contained, no URL/name/alias bytes
        }

        func description(_ box: Box, audio: Bool) throws -> (Int, Int) {
            let p = try full(box)
            try need(p, 8, in: box.body)
            guard u32(p + 4) == 1 else { throw Failure.unsupported }
            let entries = try boxes((p + 8)..<box.body.upperBound, depth: 7)
            guard entries.count == 1 else { throw Failure.malformed }
            let entry = entries[0], e = entry.body.lowerBound
            try need(e, audio ? 28 : 78, in: entry.body)
            guard zero(e..<(e + 6)), u16(e + 6) == 1 else { throw Failure.unsupported }
            if audio {
                guard entry.type == "mp4a", zero((e + 8)..<(e + 16)), u16(e + 18) == 16,
                      u32(e + 20) == 0 else { throw Failure.format }
                let channels = u16(e + 16), rateWord = u32(e + 24)
                guard channels == 1 || channels == 2, rateWord == 44_100 << 16 || rateWord == 48_000 << 16 else {
                    throw Failure.format
                }
                let children = try boxes((e + 28)..<entry.body.upperBound, depth: 8)
                guard children.count == 1, children[0].type == "esds" else { throw Failure.unsupported }
                try aac(children[0], rate: Int(rateWord >> 16), channels: channels)
                return (Int(rateWord >> 16), channels)
            }
            guard entry.type == "avc1", zero((e + 8)..<(e + 24)), u16(e + 24) > 0, u16(e + 26) > 0,
                  u32(e + 28) == 0x480000, u32(e + 32) == 0x480000, u32(e + 36) == 0,
                  u16(e + 40) == 1, b[e + 42] <= 31, u16(e + 74) == 24, u16(e + 76) == 0xffff else {
                throw Failure.format
            }
            let children = try boxes((e + 78)..<entry.body.upperBound, depth: 8)
            guard children.count == 1, children[0].type == "avcC" else { throw Failure.unsupported }
            try avc(children[0]); return (0, 0)
        }

        // MPEG-4 descriptor lengths: finite 1...4-byte base-128, exact parent consumption.
        func descriptor(_ p: inout Int, end: Int, expected: UInt8) throws -> Range<Int> {
            try need(p, 2, in: 0..<end)
            guard b[p] == expected else { throw Failure.unsupported }; p += 1
            var length = 0, terminated = false
            for _ in 0..<4 {
                try need(p, 1, in: 0..<end)
                let byte = b[p]; p += 1; length = length * 128 + Int(byte & 0x7f)
                if byte & 0x80 == 0 { terminated = true; break }
            }
            guard terminated else { throw Failure.malformed }
            try need(p, length, in: 0..<end)
            let body = p..<(p + length); p += length; return body
        }
        func aac(_ box: Box, rate: Int, channels: Int) throws {
            guard box.body.count <= 4096 else { throw Failure.format }
            let start = try full(box)
            var p = start + 4
            let es = try descriptor(&p, end: box.body.upperBound, expected: 3)
            guard p == box.body.upperBound else { throw Failure.malformed }
            try need(es.lowerBound, 3, in: es)
            guard u16(es.lowerBound) > 0, b[es.lowerBound + 2] == 0 else { throw Failure.unsupported }
            var q = es.lowerBound + 3
            let config = try descriptor(&q, end: es.upperBound, expected: 4)
            try need(config.lowerBound, 13, in: config)
            let c = config.lowerBound
            guard b[c] == 0x40, b[c + 1] == 0x15 else { throw Failure.format } // MPEG-4 audio, audio stream
            var a = c + 13
            let specific = try descriptor(&a, end: config.upperBound, expected: 5)
            guard a == config.upperBound, specific.count == 2 else { throw Failure.format }
            let bits = u16(specific.lowerBound), index = rate == 44_100 ? 4 : 3
            // AOT=2 LC; indexed rate; channelConfiguration=1/2; GASpecific flags all zero.
            // Exactly 16 bits disallows SBR/PS extensions, PCE, 960 frames and dependent core.
            guard bits == (2 << 11 | index << 7 | channels << 3) else { throw Failure.format }
            let sl = try descriptor(&q, end: es.upperBound, expected: 6)
            guard q == es.upperBound, sl.count == 1, b[sl.lowerBound] == 2 else { throw Failure.unsupported }
        }

        func avc(_ box: Box) throws {
            let p = box.body.lowerBound
            guard box.body.count <= 4096 else { throw Failure.format }
            try need(p, 7, in: box.body)
            guard b[p] == 1, [66, 77, 88].contains(Int(b[p + 1])), b[p + 2] & 3 == 0,
                  b[p + 3] > 0, b[p + 4] & 0xfc == 0xfc, b[p + 4] & 3 != 2,
                  b[p + 5] & 0xe0 == 0xe0 else { throw Failure.format }
            var q = p + 6
            func nals(_ count: Int, type: UInt8) throws {
                guard count > 0 else { throw Failure.format }
                for _ in 0..<count {
                    try need(q, 2, in: box.body)
                    let size = u16(q); q += 2
                    guard size > 0 else { throw Failure.malformed }
                    try need(q, size, in: box.body)
                    guard b[q] & 0x80 == 0, b[q] & 0x1f == type else { throw Failure.format }; q += size
                }
            }
            try nals(Int(b[p + 5] & 0x1f), type: 7)
            try need(q, 1, in: box.body)
            let count = Int(b[q]); q += 1; try nals(count, type: 8)
            guard q == box.body.upperBound else { throw Failure.unsupported }
        }

        func timing(_ box: Box, count: Int, duration: Int64, audio: Bool) throws {
            let rows = try table(box, width: 8)
            guard rows.count > 0 else { throw Failure.timing }
            var samples: Int64 = 0, ticks: Int64 = 0
            for i in 0..<rows.count {
                let p = rows.start + i * 8, n = Int64(u32(p)), delta = Int64(u32(p + 4))
                guard n > 0, delta > 0, !audio || delta == 1024 else { throw Failure.timing }
                samples = try add(samples, n)
                guard samples <= Int64(count) else { throw Failure.timing }
                ticks = try add(ticks, try multiply(n, delta))
            }
            guard samples == Int64(count), ticks == duration else { throw Failure.timing }
            try charge(count) // compact repetitions count as expanded work even without an array
        }

        func extents(_ c: [String: Box], sizes: Int, fixed: Int, count: Int) throws -> [Range<Int>] {
            guard (c["stco"] == nil) != (c["co64"] == nil) else { throw Failure.malformed }
            let offsets = try only(c, c["stco"] == nil ? "co64" : "stco"), wide = offsets.type == "co64"
            let chunks = try table(offsets, width: wide ? 8 : 4)
            let runs = try table(try only(c, "stsc"), width: 12)
            guard chunks.count > 0, runs.count > 0 else { throw Failure.malformed }
            var declared: Int64 = 0
            for i in 0..<runs.count {
                let p = runs.start + i * 12, first = Int64(u32(p)), perChunk = Int64(u32(p + 4))
                let next = i + 1 < runs.count ? Int64(u32(p + 12)) : Int64(chunks.count + 1)
                guard (i != 0 || first == 1), first > 0, first <= Int64(chunks.count),
                      next > first, next <= Int64(chunks.count + 1), perChunk > 0, u32(p + 8) == 1 else {
                    throw Failure.malformed
                }
                declared = try add(declared, try multiply(next - first, perChunk))
                guard declared <= Int64(count) else { throw Failure.malformed }
            }
            guard declared == Int64(count) else { throw Failure.malformed }
            var totalBytes: Int64 = 0
            if fixed > 0 { totalBytes = try multiply(Int64(fixed), Int64(count)) }
            else {
                for i in 0..<count {
                    let n = Int64(u32(sizes + 12 + i * 4))
                    guard n > 0 else { throw Failure.extent }; totalBytes = try add(totalBytes, n)
                }
            }
            guard totalBytes <= Int64(b.count) else { throw Failure.extent }
            try charge(count)
            var result: [Range<Int>] = []; result.reserveCapacity(count)
            var run = 0, sample = 0
            for chunk in 0..<chunks.count {
                if run + 1 < runs.count, Int(u32(runs.start + (run + 1) * 12)) == chunk + 1 { run += 1 }
                let perChunk = Int(u32(runs.start + run * 12 + 4))
                let p = chunks.start + chunk * (wide ? 8 : 4)
                let rawOffset = wide ? u64(p) : UInt64(u32(p))
                guard rawOffset <= UInt64(b.count) else { throw Failure.extent }
                var cursor = Int(rawOffset)
                // Locate the one containing mdat in logarithmic work, not a per-sample scan
                // through every box. A single chunk may not jump over another box's header.
                var low = 0, high = mdats.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if mdats[mid].upperBound <= cursor { low = mid + 1 } else { high = mid }
                }
                guard low < mdats.count, cursor >= mdats[low].lowerBound else { throw Failure.extent }
                let admittedEnd = mdats[low].upperBound
                for _ in 0..<perChunk {
                    guard sample < count else { throw Failure.malformed }
                    let n = fixed > 0 ? fixed : Int(u32(sizes + 12 + sample * 4))
                    guard n > 0, n <= admittedEnd - cursor else { throw Failure.extent }
                    let end = cursor + n
                    result.append(cursor..<end); cursor = end; sample += 1
                }
            }
            guard sample == count else { throw Failure.malformed }; return result
        }
    }
}
