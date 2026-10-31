import Foundation

/// The production finalization boundary. Native probes and storage stay in the
/// caller; tests drive the same queue, recognition, cleanup and delivery order.
public enum DictationProcessing {
    public static func final<Context>(operation: PendingOperation, samples: [Float], window: StreamWindow?,
        prepare: () async -> RecognitionHandle?,
        observed: ((RecognitionHandle, RecognitionFinalResult) -> Void)? = nil,
        recognized: (RecognitionHandle, String?) async -> Context?,
        clean: (Context) async -> (text: String, failure: String?),
        completed: (Context, String, String?) async -> Void) async {
        guard !operation.shouldAbort else { return }
        let setup = operation.diagnostics?.begin(.finalizationSetup)
        let prepared = await prepare()
        setup?.end()
        guard !operation.shouldAbort, let handle = prepared else { return }
        operation.diagnostics?.recognition(request: handle.request, resolved: true)
        operation.advance(.recognizing)
        let recognition = await handle.finalResult(samples: samples, window: window, shouldAbort: { operation.shouldAbort }, diagnostics: operation.diagnostics)
        guard !operation.shouldAbort else { return }
        observed?(handle, recognition)
        guard let context = await recognized(handle, recognition.text), !operation.shouldAbort else { return }
        operation.advance(.cleaning)
        let cleanup = operation.diagnostics?.begin(.cleanup)
        let result = await clean(context)
        cleanup?.end()
        // Pipeline deliberately catches failures and cancellation. Its raw/local
        // fallback does not grant a discarded operation delivery authority.
        guard !operation.shouldAbort else { return }
        await completed(context, result.text, result.failure)
    }
    public static func stream(operation: PendingOperation, handle: RecognitionHandle, samples: [Float],
                              pass: RecognitionHandle.Pass, sampleRange: Range<Int>? = nil, capturing: @escaping () -> Bool) async -> String? {
        guard !operation.shouldAbort, capturing() else { return nil }
        operation.advance(.recognizing)
        let result = await handle.recognize(samples, pass: pass, sampleRange: sampleRange, shouldAbort: { operation.shouldAbort || !capturing() }, diagnostics: operation.diagnostics)
        return operation.shouldAbort || !capturing() ? nil : result.text
    }

    public static func command(operation: PendingOperation, handle: RecognitionHandle, samples: [Float]) async -> String? {
        guard !operation.shouldAbort else { return nil }
        operation.advance(.recognizing)
        return await handle.commandResult(samples: samples, shouldAbort: { operation.shouldAbort }, diagnostics: operation.diagnostics).text
    }

    public static func transform(operation: PendingOperation,
                                 request: () async throws -> String) async -> (text: String, failure: String?)? {
        guard !operation.shouldAbort else { return nil }
        operation.advance(.cleaning)
        let cleanup = operation.diagnostics?.begin(.cleanup); defer { cleanup?.end() }
        let result: (String, String?)
        do { result = (try await request(), nil) }
        catch { result = ("", IntentionalTransform.failureMessage(error)) }
        guard !operation.shouldAbort else { return nil }
        return result
    }

}
