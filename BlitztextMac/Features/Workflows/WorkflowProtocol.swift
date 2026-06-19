import Foundation

// MARK: - Workflow Types

enum WorkflowType: String, CaseIterable, Identifiable, Codable {
    case transcription
    case localTranscription
    case textImprover
    case dampfAblassen
    case emojiText

    var id: String { rawValue }

    static var mainMenuCases: [WorkflowType] {
        allCases.filter { $0 != .localTranscription }
    }

    var displayName: String {
        switch self {
        case .transcription: return "Blitztext"
        case .localTranscription: return "Blitztext Lokal"
        case .textImprover: return "Blitztext+"
        case .dampfAblassen: return "Blitztext $%&!"
        case .emojiText: return "Blitztext :)"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "mic.fill"
        case .localTranscription: return "lock.shield.fill"
        case .textImprover: return "text.badge.checkmark"
        case .dampfAblassen: return "flame.fill"
        case .emojiText: return "face.smiling"
        }
    }

    var subtitle: String {
        switch self {
        case .transcription: return "Sprache rein. Text raus."
        case .localTranscription: return "Nur lokal. Kein Server."
        case .textImprover: return "Geschrieben sprechen."
        case .dampfAblassen: return "Frust rein. Entspannt raus."
        case .emojiText: return "Text rein. Emojis dazu."
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .transcription: return "fn + Shift"
        case .localTranscription: return "fn + Shift + Ctrl"
        case .textImprover: return "fn + Control"
        case .dampfAblassen: return "fn + Option"
        case .emojiText: return "fn + Cmd"
        }
    }

    var accentColor: String {
        switch self {
        case .transcription: return "blue"
        case .localTranscription: return "green"
        case .textImprover: return "purple"
        case .dampfAblassen: return "orange"
        case .emojiText: return "cyan"
        }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - App Settings

struct AppSettings: Codable {
    var hotkeyMode: HotkeyMode = .hold
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - API Provider

enum APIProvider: String, Codable, CaseIterable, Identifiable {
    case openai
    case scaleway
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .scaleway: return "Scaleway"
        case .custom: return "Eigener"
        }
    }
}

/// Resolved, immutable endpoint configuration handed to the services.
/// URLs are optional because a custom provider may not have a base URL set yet.
struct ProviderConfig {
    let transcriptionsURL: URL?
    let chatCompletionsURL: URL?
    let transcriptionModel: String
    let chatModelLight: String
    let chatModelHeavy: String
    let apiKey: String?
}

struct ProviderSettings: Codable {
    var activeProvider: APIProvider = .openai
    var scalewayChatModel: String = ""
    var customBaseURL: String = ""
    var customTranscriptionModel: String = ""
    var customChatModel: String = ""

    init(
        activeProvider: APIProvider = .openai,
        scalewayChatModel: String = "",
        customBaseURL: String = "",
        customTranscriptionModel: String = "",
        customChatModel: String = ""
    ) {
        self.activeProvider = activeProvider
        self.scalewayChatModel = scalewayChatModel
        self.customBaseURL = customBaseURL
        self.customTranscriptionModel = customTranscriptionModel
        self.customChatModel = customChatModel
    }

    enum CodingKeys: String, CodingKey {
        case activeProvider
        case scalewayChatModel
        case customBaseURL
        case customTranscriptionModel
        case customChatModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeProvider = try container.decodeIfPresent(APIProvider.self, forKey: .activeProvider) ?? .openai
        scalewayChatModel = try container.decodeIfPresent(String.self, forKey: .scalewayChatModel) ?? ""
        customBaseURL = try container.decodeIfPresent(String.self, forKey: .customBaseURL) ?? ""
        customTranscriptionModel = try container.decodeIfPresent(String.self, forKey: .customTranscriptionModel) ?? ""
        customChatModel = try container.decodeIfPresent(String.self, forKey: .customChatModel) ?? ""
    }

    func resolvedConfig(apiKey: String?) -> ProviderConfig {
        let baseURLString: String
        let transcriptionModel: String
        let chatModelLight: String
        let chatModelHeavy: String

        switch activeProvider {
        case .openai:
            baseURLString = "https://api.openai.com/v1"
            transcriptionModel = "whisper-1"
            chatModelLight = "gpt-4o-mini"
            chatModelHeavy = "gpt-4o"
        case .scaleway:
            baseURLString = "https://api.scaleway.ai/v1"
            transcriptionModel = "whisper-large-v3"
            chatModelLight = scalewayChatModel
            chatModelHeavy = scalewayChatModel
        case .custom:
            baseURLString = Self.normalizedBaseURL(customBaseURL)
            transcriptionModel = customTranscriptionModel
            chatModelLight = customChatModel
            chatModelHeavy = customChatModel
        }

        let transcriptionsURL = baseURLString.isEmpty ? nil : URL(string: baseURLString + "/audio/transcriptions")
        let chatCompletionsURL = baseURLString.isEmpty ? nil : URL(string: baseURLString + "/chat/completions")

        return ProviderConfig(
            transcriptionsURL: transcriptionsURL,
            chatCompletionsURL: chatCompletionsURL,
            transcriptionModel: transcriptionModel,
            chatModelLight: chatModelLight,
            chatModelHeavy: chatModelHeavy,
            apiKey: apiKey
        )
    }

    private static func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }
}
