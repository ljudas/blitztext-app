import Foundation

enum TranscriptionError: LocalizedError {
    case noFile
    case notConfigured
    case networkError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            return "Keine Audio-Datei gefunden"
        case .notConfigured:
            return "API-Key oder Endpoint fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .apiError(let msg):
            return "Anbieter-Fehler: \(msg)"
        }
    }
}

private struct TranscriptionOpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

private struct TranscriptionTextResponse: Decodable {
    let text: String
}

enum TranscriptionService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static func transcribe(
        audioURL: URL,
        config: ProviderConfig,
        customTerms: [String] = [],
        language: String? = nil
    ) async throws -> String {
        guard let apiKey = config.apiKey, let transcriptionsURL = config.transcriptionsURL else {
            throw TranscriptionError.notConfigured
        }
        let transcriptionModel = config.transcriptionModel

        return try await Task.detached(priority: .userInitiated) {
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let boundary = UUID().uuidString
            var request = URLRequest(url: transcriptionsURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let audioData = try Data(contentsOf: audioURL, options: [.mappedIfSafe])

            var body = Data()
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
            body.append("Content-Type: audio/wav\r\n\r\n")
            body.append(audioData)
            body.append("\r\n")

            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            body.append(transcriptionModel)
            body.append("\r\n")

            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
            body.append("json")
            body.append("\r\n")

            if !customTerms.isEmpty {
                let prompt = "Eigennamen und Begriffe: \(customTerms.joined(separator: ", "))"
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
                body.append(prompt)
                body.append("\r\n")
            }

            if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
                body.append(language.trimmingCharacters(in: .whitespacesAndNewlines))
                body.append("\r\n")
            }

            body.append("--\(boundary)--\r\n")
            request.httpBody = body

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.networkError("Ungueltige Antwort")
            }

            guard httpResponse.statusCode == 200 else {
                throw TranscriptionError.apiError(openAIErrorMessage(from: data) ?? "Status \(httpResponse.statusCode)")
            }

            let transcript: String
            if let decoded = try? JSONDecoder().decode(TranscriptionTextResponse.self, from: data) {
                // OpenAI-kompatible Provider liefern { "text": "..." }
                transcript = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Fallback: Provider hat plain text geliefert
                transcript = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            guard !transcript.isEmpty else {
                throw TranscriptionError.apiError("Transkription fehlgeschlagen")
            }

            return transcript
        }.value
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(TranscriptionOpenAIErrorResponse.self, from: data))?.error?.message
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
