import Foundation

/// Cleanup via any OpenAI-compatible /chat/completions endpoint (OpenAI, Ollama, etc.).
/// `apiKey` is optional so keyless local servers (Ollama) work without an Authorization header.
/// `model` is optional too: when nil, the server's first listed model is used.
public struct OpenAICompatClient: CleanupProviding {
    let baseURL: String
    let apiKey: String?
    let model: String?
    let http: HTTPPosting

    public init(baseURL: String, apiKey: String?, model: String?,
                http: HTTPPosting = URLSessionPoster()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    // ponytail: re-fetched every call when model is empty; cache it if the
    // extra GET per dictation ever matters.
    private func firstServerModel(base: String) async throws -> String {
        guard let url = URL(string: base + "/models") else {
            throw CleanupError(description: "invalid cleanup base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 15
        let (data, response) = try await http.post(req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CleanupError.api(statusCode: code, data: data)
        }
        struct Models: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let ids = try JSONDecoder().decode(Models.self, from: data).data.map(\.id)
        // ponytail: keyword blocklist — /models carries no capability info, so
        // skip the obvious non-chat families (Groq lists whisper first); probe
        // with a tiny chat request if a provider ever names one innocently.
        let nonChat = ["whisper", "tts", "embed", "guard", "moderation", "rerank", "audio", "orpheus"]
        guard let first = ids.first(where: { id in
            !nonChat.contains { id.lowercased().contains($0) }
        }) else {
            throw CleanupError(description: "no chat-capable model in server list — set one in Hub → AI Cleanup")
        }
        return first
    }

    public func clean(transcript: String, context: CleanupContext) async throws -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let modelID: String
        if let model { modelID = model } else { modelID = try await firstServerModel(base: base) }
        guard let url = URL(string: base + "/chat/completions") else {
            throw CleanupError(description: "invalid cleanup base URL: \(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        // See CleanupClient: idle timeout on a non-streaming completion, so it
        // bounds total generation time. 15s cut off long dictations.
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": modelID,
            // Modern OpenAI cap; max_tokens stays absent for o-series/gpt-5-class.
            "max_completion_tokens": 4096,
            // Server-default sampling avoids o-series/gpt-5 temperature rejects; degenerate guard covers loops.
            "messages": [
                ["role": "system", "content": PromptBuilder.system(context: context)],
                ["role": "user",
                 "content": PromptBuilder.user(transcript: transcript, context: context)],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.post(req)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CleanupError.api(statusCode: code, data: data)
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Part: Decodable { let text: String? }

                    let content: String?
                    let refusal: String?

                    enum CodingKeys: String, CodingKey { case content, refusal }

                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        refusal = try c.decodeIfPresent(String.self, forKey: .refusal)
                        if let text = try? c.decodeIfPresent(String.self, forKey: .content) {
                            content = text
                            return
                        }
                        let parts = (try? c.decodeIfPresent([Part].self, forKey: .content)) ?? []
                        let text = parts.compactMap(\.text).joined()
                        content = text.isEmpty ? nil : text
                    }
                }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // `modelID`, not `model`: when the model field is empty this is the id
        // the server actually picked, which is the one that got billed.
        Metrics.shared.update {
            $0.cleanupModel = modelID
            $0.promptTokens = decoded.usage?.prompt_tokens
            $0.completionTokens = decoded.usage?.completion_tokens
        }
        switch decoded.choices.first?.finish_reason {
        case let reason? where reason == "length" || reason == "content_filter":
            throw CleanupError(description: "cleanup response stopped (finish_reason=\(reason))")
        default:
            break
        }
        if let refusal = decoded.choices.first?.message.refusal, !refusal.isEmpty {
            throw CleanupError(description: "cleanup response refused: \(refusal)")
        }
        let text = decoded.choices.first?.message.content ?? ""
        guard !text.isEmpty else { throw CleanupError(description: "empty response") }
        return text
    }
}
