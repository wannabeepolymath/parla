import AVFoundation
import Foundation
import XCTest
@testable import ParlaCore

private func authoredWAV(rate: Int, frames: Int, signal: Int) -> Data {
    func le(_ value: Int, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    var pcm = Data(); pcm.reserveCapacity(frames * 2)
    for i in 0..<frames {
        let value: Int
        switch signal {
        case 0: value = (i * 97 % 40_001) - 20_000 // authored ramp
        case 1: value = i == frames - 1 ? 24_000 : 0 // last-frame impulse
        case 2: value = Int(12_000 * sin(2 * .pi * 317 * Double(i) / Double(rate)))
        case 3: value = 0
        default: value = [Int(Int16.min), Int(Int16.max), -1, 0][i % 4]
        }
        pcm.append(le(value, 2))
    }
    let format = le(1, 2) + le(1, 2) + le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2)
    let chunks = Data("fmt ".utf8) + le(16, 4) + format + Data("data".utf8) + le(pcm.count, 4) + pcm
    return Data("RIFF".utf8) + le(chunks.count + 4, 4) + Data("WAVE".utf8) + chunks
}

private final class NativeObservation {
    var creations = 0, calls = 0, callbacks = 0, supplied = 0, output = 0
    var inputEOS = false, outputEOS = false, oneFrameCalls = 0
    var leading: AVAudioFrameCount = 0, trailing: AVAudioFrameCount = 0
    var lastStatus = -1, lastFrames = -1
    func native() -> ImportedAudio.Native {
        let real = ImportedAudio.Native()
        var native = real
        native.make = { from, to in self.creations += 1; return real.make(from, to) }
        native.configure = { converter in
            real.configure(converter)
            self.leading = converter.primeInfo.leadingFrames; self.trailing = converter.primeInfo.trailingFrames
        }
        native.convert = { converter, buffer, input in
            self.calls += 1
            if buffer.frameCapacity == 1 { self.oneFrameCalls += 1 }
            let step = real.convert(converter, buffer) { request, status in
                self.callbacks += 1
                let result = input(request, status)
                if status.pointee == .endOfStream { self.inputEOS = true }
                if let pcm = result as? AVAudioPCMBuffer { self.supplied += Int(pcm.frameLength) }
                return result
            }
            self.output += Int(buffer.frameLength)
            self.lastStatus = step.status.rawValue; self.lastFrames = Int(buffer.frameLength)
            self.outputEOS = step.status == .endOfStream && buffer.frameLength == 0
            return step
        }
        return native
    }
    var evidence: String {
        "creations=\(creations) calls=\(calls) callbacks=\(callbacks) supplied=\(supplied) output=\(output) inputEOS=\(inputEOS) outputEOS=\(outputEOS) tailCalls=\(oneFrameCalls) prime=\(leading)/\(trailing) lastStatus=\(lastStatus) lastFrames=\(lastFrames)"
    }
}

final class ImportedAudioTests: XCTestCase {
    func testN1RealNativeAuthoredPCMAllRatesChunkInvarianceAndDrain() throws {
        // Predeclared in wave7b1-design.md before execution: identical counts and abs error <= 0.00001.
        let tolerance: Float = 0.00001
        for rate in [8000, 22050, 24000, 32000, 44100, 48000] {
            for signal in 0..<5 {
                for extra in [0, 1, 137] {
                    let n = rate * 2 / 5 + extra
                    let bytes = authoredWAV(rate: rate, frames: n, signal: signal)
                    var reference: [Float]?
                    for chunk in [4096, 1, 127] {
                        let observation = NativeObservation()
                        let label = "N1 rate=\(rate) N=\(n) signal=\(signal) chunk=\(chunk) floor=\(n * 16000 / rate) ceil=\((n * 16000 + rate - 1) / rate)"
                        let decoded: ImportedAudio.Decoded
                        do { decoded = try ImportedAudio.decode(bytes, native: observation.native(), inputChunkLimit: chunk) }
                        catch {
                            print("\(label) REFUSED=\(error) \(observation.evidence)")
                            throw error // The first failed native predicate stops this gate.
                        }
                        print("\(label) \(observation.evidence)")
                        guard observation.creations == 1, observation.supplied == n,
                              observation.inputEOS, observation.outputEOS, observation.lastFrames == 0,
                              observation.oneFrameCalls > 0, decoded.samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) }),
                              decoded.transientSourceInfo.sourceRate == rate, decoded.transientSourceInfo.sourceFrames == n,
                              decoded.transientSourceInfo.outputFrames == decoded.samples.count else {
                            XCTFail("Native accounting/finite/tail predicate failed: \(label) \(observation.evidence)")
                            return
                        }
                        if signal == 1, !decoded.samples.suffix(256).contains(where: { abs($0) > 0.000001 }) {
                            XCTFail("Final impulse tail absent: \(label)"); return
                        }
                        if let reference {
                            guard reference.count == decoded.samples.count else {
                                XCTFail("Chunk count differs: \(label) reference=\(reference.count) actual=\(decoded.samples.count)"); return
                            }
                            let difference = zip(reference, decoded.samples).map { abs($0 - $1) }.max() ?? 0
                            guard difference <= tolerance else {
                                XCTFail("Chunk sample difference: \(label) maxAbs=\(difference) limit=\(tolerance)"); return
                            }
                        } else { reference = decoded.samples }
                    }
                }
            }
        }
    }
}

// Drives the actual parser, source cursor and drain accounting with only the native call replaced.
private final class ShortStatusNative {
    let firstStatus: AVAudioConverterOutputStatus
    var calls = 0, supplied = 0, output = 0
    var inputEOS = false, outputEOS = false
    init(_ firstStatus: AVAudioConverterOutputStatus) { self.firstStatus = firstStatus }
    func native() -> ImportedAudio.Native {
        var native = ImportedAudio.Native()
        native.convert = { _, buffer, input in
            self.calls += 1
            if self.calls == 1 {
                var status = AVAudioConverterInputStatus.noDataNow
                while let pcm = input(4096, &status) as? AVAudioPCMBuffer {
                    self.supplied += Int(pcm.frameLength)
                }
                self.inputEOS = status == .endOfStream
            }
            if self.output == 6400 {
                buffer.frameLength = 0; self.outputEOS = true
                return ImportedAudio.Step(status: .endOfStream)
            }
            let count = self.calls == 1 ? 4095 : min(Int(buffer.frameCapacity), 6400 - self.output)
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = 0 }
            self.output += count
            return ImportedAudio.Step(status: self.calls == 1 ? self.firstStatus : .haveData)
        }
        return native
    }
}

extension ImportedAudioTests {
    func testPStatusShortHaveDataAndInputRanDry() throws {
        let bytes = authoredWAV(rate: 8000, frames: 3200, signal: 3)
        let shortHaveData = ShortStatusNative(.haveData)
        XCTAssertThrowsError(try ImportedAudio.decode(bytes, native: shortHaveData.native())) {
            XCTAssertEqual($0 as? ImportedAudio.Failure, .output)
        }
        XCTAssertEqual(shortHaveData.supplied, 3200)
        XCTAssertTrue(shortHaveData.inputEOS)
        XCTAssertFalse(shortHaveData.outputEOS)
        XCTAssertEqual(shortHaveData.calls, 1)
        print("STATUS afterGuard shortHaveData refused=output calls=\(shortHaveData.calls) supplied=\(shortHaveData.supplied) inputEOS=\(shortHaveData.inputEOS) outputEOS=\(shortHaveData.outputEOS)")
        let shortRanDry = ShortStatusNative(.inputRanDry)
        let decoded = try ImportedAudio.decode(bytes, native: shortRanDry.native())
        XCTAssertEqual(decoded.samples.count, 6400)
        XCTAssertEqual(shortRanDry.supplied, 3200)
        XCTAssertTrue(shortRanDry.inputEOS && shortRanDry.outputEOS)
        XCTAssertEqual(shortRanDry.calls, 3)
        print("STATUS shortInputRanDry accepted=\(decoded.samples.count) calls=\(shortRanDry.calls) supplied=\(shortRanDry.supplied) inputEOS=\(shortRanDry.inputEOS) outputEOS=\(shortRanDry.outputEOS)")
    }
}

// Authored 44.1 kHz boundary through the real parser/driver; only native output is scripted.
private final class FractionalStatusNative {
    enum Ending: String, CaseIterable {
        case floorEOS, ceilEOS, missingInputEOS, belowFloor, excess, error, nan, infinity, noProgress, nonzeroEOS
    }
    let ending: Ending
    var calls = 0, creations = 0, supplied = 0
    var inputEOS = false
    var capacities: [Int] = [], counts: [Int] = [], statuses: [Int] = []
    weak var converter: AVAudioConverter?
    weak var inputBuffer: AVAudioPCMBuffer?
    weak var outputBuffer: AVAudioPCMBuffer?
    init(_ ending: Ending) { self.ending = ending }
    func native() -> ImportedAudio.Native {
        let real = ImportedAudio.Native()
        var native = real
        native.make = { from, to in
            self.creations += 1
            let converter = real.make(from, to)
            self.converter = converter
            return converter
        }
        native.convert = { converter, buffer, input in
            XCTAssertTrue(self.converter === converter)
            XCTAssertEqual(buffer.frameLength, 0)
            self.outputBuffer = buffer
            self.calls += 1
            self.capacities.append(Int(buffer.frameCapacity))
            if self.calls <= 2 {
                let target = self.calls == 1 ? 11_306 : 17_641
                var status = AVAudioConverterInputStatus.noDataNow
                while self.supplied < target {
                    guard let pcm = input(AVAudioPacketCount(min(4096, target - self.supplied)), &status) as? AVAudioPCMBuffer else {
                        XCTFail("Source ended before authored target"); break
                    }
                    self.inputBuffer = pcm
                    XCTAssertEqual(status, .haveData)
                    self.supplied += Int(pcm.frameLength)
                }
                if self.calls == 2, self.ending != .missingInputEOS {
                    XCTAssertNil(input(1, &status))
                    self.inputEOS = status == .endOfStream
                }
            }
            let count: Int
            let status: AVAudioConverterOutputStatus
            var error: NSError?
            if self.calls == 1 { count = 4096; status = .haveData }
            else if self.calls == 2 {
                count = self.ending == .belowFloor ? 2303 : 2304; status = .haveData
            } else {
                switch self.ending {
                case .ceilEOS, .excess:
                    count = self.calls == 3 || self.ending == .excess ? 1 : 0
                    status = count == 0 ? .endOfStream : .haveData
                case .error:
                    count = 1; status = .error
                    error = NSError(domain: "AuthoredPCMTest", code: 7)
                case .noProgress: count = 0; status = .inputRanDry
                case .nonzeroEOS: count = 1; status = .endOfStream
                default: count = 0; status = .endOfStream
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = 0 }
            if self.calls == 2, self.ending == .nan { buffer.floatChannelData![0][count - 1] = .nan }
            if self.calls == 2, self.ending == .infinity { buffer.floatChannelData![0][count - 1] = .infinity }
            self.counts.append(count); self.statuses.append(status.rawValue)
            return ImportedAudio.Step(status: status, error: error)
        }
        return native
    }
}

extension ImportedAudioTests {
    private func checkFractionalStatus(_ ending: FractionalStatusNative.Ending) {
        let fake = FractionalStatusNative(ending)
        let positive = ending == .floorEOS || ending == .ceilEOS
        autoreleasepool {
            do {
                let decoded = try ImportedAudio.decode(authoredWAV(rate: 44_100, frames: 17_641, signal: 0), native: fake.native())
                XCTAssertTrue(positive, "Unexpected accepted \(ending.rawValue)")
                XCTAssertEqual(decoded.samples.count, ending == .ceilEOS ? 6401 : 6400)
                XCTAssertEqual(decoded.transientSourceInfo.outputFrames, decoded.samples.count)
                XCTAssertEqual(decoded.transientSourceInfo.sourceFrames, 17_641)
                XCTAssertEqual(decoded.transientSourceInfo.clippedSamples, 0)
                XCTAssertTrue(decoded.samples.allSatisfy { $0 == 0 })
                print("FRACTIONAL \(ending.rawValue) accepted=\(decoded.samples.count)")
            } catch {
                XCTAssertFalse(positive, "Expected complete \(ending.rawValue), got \(error)")
                XCTAssertEqual(error as? ImportedAudio.Failure, ending == .error ? .native : .output)
                print("FRACTIONAL \(ending.rawValue) refused=\(error)")
            }
        }
        let expectedCalls: Int
        switch ending {
        case .ceilEOS, .excess: expectedCalls = 4
        case .floorEOS, .error, .noProgress, .nonzeroEOS: expectedCalls = 3
        default: expectedCalls = 2
        }
        XCTAssertEqual(fake.creations, 1)
        XCTAssertEqual(fake.calls, expectedCalls, ending.rawValue)
        XCTAssertEqual(fake.capacities, Array([4096, 2305, 1, 1].prefix(expectedCalls)))
        XCTAssertEqual(fake.supplied, 17_641)
        XCTAssertEqual(fake.inputEOS, ending != .missingInputEOS)
        XCTAssertNil(fake.converter, "Converter must unwind at actual decode exit")
        XCTAssertNil(fake.inputBuffer, "Input buffer must unwind at actual decode exit")
        XCTAssertNil(fake.outputBuffer, "Output buffer must unwind at actual decode exit")
        print("FRACTIONAL \(ending.rawValue) creations=\(fake.creations) calls=\(fake.calls) capacities=\(fake.capacities) counts=\(fake.counts) statuses=\(fake.statuses) supplied=\(fake.supplied) inputEOS=\(fake.inputEOS) disposed=\(fake.converter == nil && fake.inputBuffer == nil && fake.outputBuffer == nil)")
    }
    func testPFractionalFloorThenZeroEOS() { checkFractionalStatus(.floorEOS) }
    func testPFractionalFloorThenCeilThenZeroEOS() { checkFractionalStatus(.ceilEOS) }
    func testPFractionalRefusals() {
        for ending in FractionalStatusNative.Ending.allCases where ending != .floorEOS && ending != .ceilEOS {
            checkFractionalStatus(ending)
        }
    }
}

extension ImportedAudioTests {
    func testP1Strict16kDelegatesWithoutNativeCreation() throws {
        var native = ImportedAudio.Native()
        native.make = { _, _ in XCTFail("Strict 16k entered converter"); return nil }
        for signal in 0..<5 {
            let bytes = authoredWAV(rate: 16_000, frames: 6400, signal: signal)
            let decoded = try ImportedAudio.decode(bytes, native: native)
            XCTAssertEqual(decoded.samples, try ImportedWAV.decode(bytes))
            XCTAssertEqual(decoded.transientSourceInfo.origin, .strictPCM16k)
            XCTAssertEqual(decoded.transientSourceInfo.clippedSamples, 0)
        }
        let bytes = authoredWAV(rate: 16_000, frames: 6399, signal: 0)
        XCTAssertThrowsError(try ImportedWAV.decode(bytes))
        XCTAssertThrowsError(try ImportedAudio.decode(bytes, native: native))
        XCTAssertThrowsError(try ImportedAudio.decode(authoredWAV(rate: 16_000, frames: 6400, signal: 0), canceled: { true }, native: native)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testP2P3P4CompleteGrammarAndBudgetsBeforeNativeCreation() throws {
        func le(_ n: Int, _ c: Int) -> Data { Data((0..<c).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        func riff(_ chunks: Data) -> Data { Data("RIFF".utf8) + le(chunks.count + 4, 4) + Data("WAVE".utf8) + chunks }
        func chunk(_ tag: String, _ data: Data, pad: Bool = true) -> Data {
            Data(tag.utf8) + le(data.count, 4) + data + (pad && data.count & 1 != 0 ? Data([0]) : Data())
        }
        var creations = 0
        var native = ImportedAudio.Native()
        native.make = { _, _ in creations += 1; return nil }
        func expect(_ bytes: Data, admitted: Bool) {
            let before = creations
            XCTAssertThrowsError(try ImportedAudio.decode(bytes, native: native))
            XCTAssertEqual(creations - before, admitted ? 1 : 0)
        }
        for rate in [8000, 22050, 24000, 32000, 44100, 48000] {
            let base = authoredWAV(rate: rate, frames: rate * 2 / 5, signal: 3)
            let fmt = base.subdata(in: 12..<36), pcm = Data(base.dropFirst(36)), junk = chunk("JUNK", Data())
            expect(base, admitted: true)
            expect(authoredWAV(rate: rate, frames: rate * 2 / 5 - 1, signal: 3), admitted: false)
            expect(authoredWAV(rate: rate, frames: rate * 2 / 5 + 1, signal: 3), admitted: true)
            for offset in [20, 22, 24, 28, 32, 34] {
                var bad = base; bad[offset] ^= 1; expect(bad, admitted: false)
            }
            let invalid = [riff(fmt + pcm + pcm), riff(pcm + fmt), riff(fmt + pcm + fmt),
                riff(fmt), riff(fmt + chunk("data", Data([0, 1, 2]))),
                riff(fmt + pcm + chunk("JUNK", Data([1]), pad: false)),
                base + Data([0]), Data(base.dropLast()),
                riff(fmt + pcm + Data("JUNK".utf8) + le(Int(UInt32.max), 4)),
                riff(chunk("fmt ", Data(base[20..<36]) + Data([0, 0])) + pcm),
                riff(fmt + pcm + Data((0..<127).flatMap { _ in junk }))]
            for bad in invalid { expect(bad, admitted: false) }
            expect(riff(chunk("JUNK", Data([9])) + fmt + pcm + chunk("LIST", Data([8]))), admitted: true)
            expect(riff(fmt + pcm + Data((0..<126).flatMap { _ in junk })), admitted: true)
            for tag in ["RIFX", "RF64", "ftyp"] {
                var bad = base; bad.replaceSubrange(0..<4, with: tag.utf8); expect(bad, admitted: false)
            }
        }
        // Allocate authored zero Int16 payload without a full source Float array or native conversion.
        func silent(_ rate: Int, _ n: Int) -> Data {
            let format = le(1, 2) + le(1, 2) + le(rate, 4) + le(rate * 2, 4) + le(2, 2) + le(16, 2)
            return riff(chunk("fmt ", format) + chunk("data", Data(repeating: 0, count: n * 2)))
        }
        expect(silent(8000, 4_800_000), admitted: true)
        expect(silent(8000, 4_800_001), admitted: false)
        expect(silent(48000, 28_800_000), admitted: false) // 600s fails the independent byte limit.
        let largest48k = (ImportedWAV.maximumBytes - 44) / 2
        expect(silent(48000, largest48k), admitted: true)
        expect(silent(48000, largest48k + 1), admitted: false)
        expect(Data(repeating: 0, count: ImportedWAV.maximumBytes + 1), admitted: false)
        let base = silent(8000, 3200)
        expect(riff(Data(base.dropFirst(12)) + chunk("JUNK", Data(repeating: 0, count: ImportedWAV.maximumBytes - base.count - 8))), admitted: true)
    }

    func testP5NativeConfigurationAndPrimeRefusals() throws {
        let bytes = authoredWAV(rate: 8000, frames: 3200, signal: 0)
        for variant in 0..<5 {
            var native = ImportedAudio.Native()
            var calls = 0
            switch variant {
            case 0: native.make = { _, _ in nil }
            case 1: native.make = { _, to in AVAudioConverter(from: to, to: to) }
            case 2: native.configure = { $0.primeMethod = .none }
            case 3: native.primeInfo = { _ in AVAudioConverterPrimeInfo(leadingFrames: 16_385, trailingFrames: 0) }
            default: native.primeInfo = { _ in AVAudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 16_385) }
            }
            native.convert = { _, _, _ in calls += 1; return .init(status: .error) }
            XCTAssertThrowsError(try ImportedAudio.decode(bytes, native: native)) { XCTAssertEqual($0 as? ImportedAudio.Failure, .native) }
            XCTAssertEqual(calls, 0)
        }
    }

    func testP5P6FiniteClippingStatusesCallbacksAndCallBounds() throws {
        for variant in 0..<12 {
            let frames = variant == 10 ? 48_000 : 19_200
            let bytes = authoredWAV(rate: 48_000, frames: frames, signal: 0)
            var native = ImportedAudio.Native(), calls = 0, callbacks = 0, supplied = 0, output = 0
            var canceled = false
            native.convert = { _, buffer, input in
                calls += 1
                var status = AVAudioConverterInputStatus.noDataNow
                if calls == 1 {
                    if variant == 0 || variant == 1 {
                        _ = input(variant == 0 ? 0 : UInt32.max, &status); callbacks += 1
                    } else if variant == 9 {
                        for _ in 0..<131_073 { _ = input(1, &status); callbacks += 1 }
                    } else if variant != 3 && variant != 4 {
                        while let pcm = input(4096, &status) as? AVAudioPCMBuffer {
                            callbacks += 1; supplied += Int(pcm.frameLength)
                        }
                        callbacks += 1
                    }
                }
                if variant == 11 { canceled = true }
                if variant == 2 { buffer.frameLength = 1; return .init(status: .endOfStream) }
                if variant == 3 { buffer.frameLength = 0; return .init(status: .endOfStream) }
                if variant == 4 { buffer.frameLength = 0; return .init(status: .inputRanDry) }
                if variant == 5 { buffer.frameLength = 1; return .init(status: .haveData, error: NSError(domain: "AuthoredPCMTest", code: 1)) }
                if variant == 6 {
                    buffer.frameLength = 1
                    return .init(status: AVAudioConverterOutputStatus(rawValue: 99)!)
                }
                if output == 6400 && variant != 10 {
                    buffer.frameLength = 0; return .init(status: .endOfStream)
                }
                let count = variant == 10 ? 1 : min(Int(buffer.frameCapacity), 6400 - output)
                buffer.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { buffer.floatChannelData![0][i] = variant == 7 ? (i % 2 == 0 ? 1.25 : -1.25) : 0 }
                output += count
                return .init(status: .inputRanDry)
            }
            if variant == 7 || variant == 8 {
                let decoded = try ImportedAudio.decode(bytes, native: native)
                XCTAssertEqual(decoded.samples.count, 6400)
                XCTAssertEqual(decoded.transientSourceInfo.clippedSamples, variant == 7 ? 6400 : 0)
                XCTAssertTrue(decoded.samples.allSatisfy { variant == 7 ? abs($0) == 1 : $0 == 0 })
                XCTAssertEqual(supplied, frames)
                XCTAssertEqual(calls, 3)
            } else {
                XCTAssertThrowsError(try ImportedAudio.decode(bytes, canceled: { canceled }, native: native)) {
                    if variant == 11 { XCTAssertTrue($0 is CancellationError) }
                }
                XCTAssertEqual(calls, variant == 10 ? 8192 : 1, "Authored variant \(variant)")
                if variant == 9 { XCTAssertEqual(callbacks, 131_073) }
            }
        }
    }
}

extension ImportedAudioTests {
    func testP6CallbackCancellationStaysLatchedAcrossNativeReturnAndZeroHaveDataRefuses() throws {
        for cancellation in [true, false] {
            var canceled = false, calls = 0
            var native = ImportedAudio.Native()
            native.convert = { _, buffer, input in
                calls += 1
                var status = AVAudioConverterInputStatus.noDataNow
                if cancellation {
                    canceled = true
                    XCTAssertNil(input(4096, &status))
                    XCTAssertEqual(status, .endOfStream)
                    canceled = false // The callback's CancellationError must survive this transient signal.
                } else {
                    XCTAssertNotNil(input(4096, &status))
                }
                buffer.frameLength = 0
                return .init(status: .haveData)
            }
            XCTAssertThrowsError(try ImportedAudio.decode(authoredWAV(rate: 8000, frames: 3200, signal: 0), canceled: { canceled }, native: native)) {
                if cancellation { XCTAssertTrue($0 is CancellationError) }
                else { XCTAssertEqual($0 as? ImportedAudio.Failure, .output) }
            }
            XCTAssertEqual(calls, 1)
        }
    }
}
