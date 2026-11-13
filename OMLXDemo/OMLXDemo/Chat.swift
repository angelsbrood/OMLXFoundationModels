import Foundation
import FoundationModels
import OMLXFoundationModels

/// Where the model runs.
enum Backend: String, CaseIterable, Identifiable {
    case mac = "Mac"
    case iPhone = "iPhone"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .mac: "macbook"
        case .iPhone: "iphone"
        }
    }
}

/// One prompt and the model's answer to it.
struct Turn: Identifiable {
    let id = UUID()
    let prompt: String
    var response = ""
    var reasoning = ""
    var tokensPerSecond: Double?
    var timeToFirstToken: Double?
    var error: String?
    var isComplete = false
}

/// A conversation with one model, rebuilt whenever the backend or connection changes.
@Observable
final class Chat {
    var backend = Backend.mac {
        didSet { startOver() }
    }
    private(set) var turns: [Turn] = []

    var isResponding: Bool {
        turns.last.map { !$0.isComplete } ?? false
    }

    @ObservationIgnored private var session: LanguageModelSession
    @ObservationIgnored private var connection: Connection
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        let connection = Connection.current
        self.connection = connection
        session = Self.makeSession(for: .mac, connection: connection)
        session.prewarm(promptPrefix: nil)
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }

        let turn = Turn(prompt: prompt)
        turns.append(turn)

        let session = session
        let contextOptions = ContextOptions(
            includeSchemaInPrompt: nil,
            reasoningLevel: backend == .mac ? Reasoning.current.level : nil
        )

        task = Task {
            do {
                let stream = session.streamResponse(to: Prompt { prompt }, contextOptions: contextOptions)
                for try await snapshot in stream {
                    update(turn.id) { $0.response = snapshot.content }
                }
                let response = try await stream.collect()
                update(turn.id) {
                    $0.response = response.content
                    $0.finish(with: response.transcriptEntries)
                }
            } catch {
                update(turn.id) {
                    if !(error is CancellationError) {
                        $0.error = error.localizedDescription
                    }
                    $0.isComplete = true
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func startOver() {
        task?.cancel()
        turns = []
        connection = Connection.current
        session = Self.makeSession(for: backend, connection: connection)
        session.prewarm(promptPrefix: nil)
    }

    /// Starts over only if the server, model, or key changed.
    func reconnectIfNeeded() {
        if Connection.current != connection {
            startOver()
        }
    }

    private func update(_ id: Turn.ID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    private static func makeSession(for backend: Backend, connection: Connection) -> LanguageModelSession {
        let instructions = Instructions {
            "You are a helpful assistant. Keep answers short."
        }
        switch backend {
        case .mac:
            let model = OMLXLanguageModel(
                name: connection.model,
                url: URL(string: connection.url) ?? URL(string: Connection.defaultURL)!,
                apiKey: connection.apiKey
            )
            return LanguageModelSession(model: model, instructions: instructions)
        case .iPhone:
            return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }
    }
}

extension Turn {
    /// Picks up the reasoning and oMLX's timing from a finished response.
    mutating func finish(with entries: some Collection<Transcript.Entry>) {
        for entry in entries {
            switch entry {
            case .reasoning(let thinking):
                reasoning += thinking.segments.text
            case .response(let answer):
                tokensPerSecond = try? answer.metadata[OMLXLanguageModel.MetadataKey.generationTokensPerSecond]?
                    .value(Double.self)
                timeToFirstToken = try? answer.metadata[OMLXLanguageModel.MetadataKey.timeToFirstToken]?
                    .value(Double.self)
            default:
                break
            }
        }
        isComplete = true
    }
}

extension Collection<Transcript.Segment> {
    var text: String {
        compactMap { segment -> String? in
            if case .text(let text) = segment { text.content } else { nil }
        }
        .joined()
    }
}
