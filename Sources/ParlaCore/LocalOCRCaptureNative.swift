import Foundation

#if os(macOS) && canImport(ScreenCaptureKit) && canImport(Vision)
import ScreenCaptureKit
import Vision
import CoreGraphics
import CoreVideo

// Immutable handles cross the joined callback boundary. The window/filter are
// read only on main after metadata extraction; CGImage is immutable. No mutable
// framework request is transferred: Vision creates/uses it in its awaited body.
public final class LocalOCRNativeWindow: @unchecked Sendable {
    fileprivate let value: SCWindow
    fileprivate init(_ value: SCWindow) { self.value = value }
}
public final class LocalOCRNativeFilter: @unchecked Sendable {
    fileprivate let value: SCContentFilter
    fileprivate let window: LocalOCRNativeWindow
    fileprivate init(_ value: SCContentFilter, window: LocalOCRNativeWindow) {
        self.value = value; self.window = window
    }
}
public final class LocalOCRNativeImage: @unchecked Sendable {
    fileprivate let value: CGImage
    fileprivate init(_ value: CGImage) { self.value = value }
}

// Transfer retention only, never mutable configuration access, to the callback.
// Configuration is fully set on main before this holder is created and is never
// mutated/read by app code after issue. The callback only retains/releases it.
private final class LocalOCRNativeIssuedLifetime: @unchecked Sendable {
    let filter: LocalOCRNativeFilter
    let configuration: SCStreamConfiguration
    init(filter: LocalOCRNativeFilter, configuration: SCStreamConfiguration) {
        self.filter = filter; self.configuration = configuration
    }
}

/// Constructing this driver performs no native work. No broad metadata route,
/// permission request, image encoding, stream, own-render or display fallback.
public struct LocalOCRNativeDriver: LocalOCRDriver {
    public init() {}
    @MainActor public var supported: Bool { if #available(macOS 14.4, *) { return true }; return false }
    @MainActor public func preflight() -> Bool {
        guard supported else { return false }
        return CGPreflightScreenCaptureAccess()
    }
    @MainActor public func lookup(_ callback: LocalOCRCallback<Result<[LocalOCRWindow<LocalOCRNativeWindow>], LocalOCRFailure>>) {
        guard #available(macOS 14.4, *) else { callback.receive { .failure(.unsupported) }; return }
        // Current-process method REQUESTED; undocumented process/permission
        // internals are UNQUALIFIED. Only count, PID, windowID and frame read.
        let ownPID = getpid()
        SCShareableContent.getCurrentProcessShareableContent { content, error in
            callback.receive {
                guard error == nil, let content else { return .failure(.platform) }
                let windows = content.windows
                guard windows.count <= 8 else { return .failure(.metadataLimit) }
                var selected: [LocalOCRWindow<LocalOCRNativeWindow>] = []
                for window in windows {
                    guard let pid = window.owningApplication?.processID, pid == ownPID
                    else { return .failure(.identityUnlinked) }
                    let frame = window.frame
                    selected.append(LocalOCRWindow(pid: pid, id: window.windowID,
                        frame: LocalOCRRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                        handle: LocalOCRNativeWindow(window)))
                }
                return .success(selected)
            }
            // Extraction body has returned; no app work after owned-body exit.
            // No assertion of framework/foreign callback-thread exit.
        }
    }
    @MainActor public func filter(_ window: LocalOCRNativeWindow) -> Result<LocalOCRFilter<LocalOCRNativeFilter>, LocalOCRFailure> {
        guard #available(macOS 14.4, *) else { return .failure(.unsupported) }
        let filter = SCContentFilter(desktopIndependentWindow: window.value)
        let rect = filter.contentRect
        return .success(LocalOCRFilter(handle: LocalOCRNativeFilter(filter, window: window),
            rect: LocalOCRRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
            scale: Double(filter.pointPixelScale)))
    }
    @MainActor public func capture(_ filter: LocalOCRNativeFilter, dimensions: LocalOCRDimensions,
        callback: LocalOCRCallback<Result<LocalOCRImage<LocalOCRNativeImage>, LocalOCRFailure>>) {
        guard #available(macOS 14.4, *) else { callback.receive { .failure(.unsupported) }; return }
        let config = SCStreamConfiguration()
        config.width = dimensions.width; config.height = dimensions.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
        let issued = LocalOCRNativeIssuedLifetime(filter: filter, configuration: config)
        SCScreenshotManager.captureImage(contentFilter: filter.value, configuration: config) { image, error in
            callback.receive {
                // Retain the issued filter/config through our complete body.
                defer { withExtendedLifetime(issued) {} }
                guard error == nil, let image else { return .failure(.platform) }
                let known = image.alphaInfo == .premultipliedFirst
                    && image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
                    && image.colorSpace?.model == .rgb && !image.isMask
                let header = LocalOCRImageHeader(width: image.width, height: image.height,
                    bitsPerPixel: image.bitsPerPixel, bitsPerComponent: image.bitsPerComponent,
                    bytesPerRow: image.bytesPerRow,
                    format: known ? .bgra8PremultipliedFirstLittleEndian : .unknown)
                guard header.valid(for: dimensions) else { return .failure(.imageFormat) }
                // No owner/window ID exists on CGImage. Do not manufacture one.
                return .success(LocalOCRImage(handle: LocalOCRNativeImage(image), header: header))
            }
        }
    }
    public func perform(_ image: LocalOCRNativeImage, operation: PendingOperation,
        callback: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>) async -> Bool {
        guard #available(macOS 14.4, *) else { callback.receive { .failure(.unsupported) }; return false }
        guard !operation.shouldAbort else { callback.receive { .failure(.revoked) }; return false }
        let request = VNRecognizeTextRequest { request, error in
            callback.receive {
                guard !operation.shouldAbort else { return .failure(.revoked) }
                guard error == nil, let observations = (request as? VNRecognizeTextRequest)?.results
                else { return .failure(.platform) }
                return LocalOCRProjection.bounded(observationCount: observations.count) { i in
                    observations[i].topCandidates(1).first?.string
                }
            }
        }
        request.revision = VNRecognizeTextRequestRevision3; request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]; request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false; request.customWords = []
        operation.installAbort { request.cancel() }
        let handler = VNImageRequestHandler(cgImage: image.value, options: [:])
        defer { withExtendedLifetime(image) {}; withExtendedLifetime(request) {}; withExtendedLifetime(handler) {} }
        do {
            // Synchronous perform in THIS awaited nonisolated body, never main,
            // detached work, a new queue or a semaphore. May wait indefinitely.
            try handler.perform([request])
            // Missing completion after perform-return is a finite platform
            // refusal. If a callback has entered, receive cannot bypass its exit.
            callback.receive { .failure(.platform) }
            return true
        } catch {
            callback.receive { .failure(.platform) }
            return false // Never stringify a platform error.
        }
    }
}
#else
/// Unsupported imports refuse before any UI/preflight/SC/Vision work.
public struct LocalOCRNativeDriver: LocalOCRDriver {
    public init() {}
    @MainActor public var supported: Bool { false }
    @MainActor public func preflight() -> Bool { false }
    @MainActor public func lookup(_ callback: LocalOCRCallback<Result<[LocalOCRWindow<Int>], LocalOCRFailure>>) {
        callback.receive { .failure(.unsupported) }
    }
    @MainActor public func filter(_ window: Int) -> Result<LocalOCRFilter<Int>, LocalOCRFailure> { .failure(.unsupported) }
    @MainActor public func capture(_ filter: Int, dimensions: LocalOCRDimensions,
        callback: LocalOCRCallback<Result<LocalOCRImage<Int>, LocalOCRFailure>>) { callback.receive { .failure(.unsupported) } }
    public func perform(_ image: Int, operation: PendingOperation,
        callback: LocalOCRCallback<Result<LocalOCRProjection, LocalOCRFailure>>) async -> Bool {
        callback.receive { .failure(.unsupported) }; return false
    }
}
#endif
