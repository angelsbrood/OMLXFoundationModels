import SwiftUI

struct ChatView: View {
    @State private var chat = Chat()
    @State private var draft = String(localized: "In two sentences, why does a 27B model run slower on a Mac than in a data center?")
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            List(chat.turns) { turn in
                TurnSection(turn: turn)
            }
            .overlay {
                if chat.turns.isEmpty {
                    ContentUnavailableView {
                        Label(chat.backend.rawValue, systemImage: chat.backend.systemImage)
                    } description: {
                        Text(chat.backend == .mac ? "Qwen, running on your Mac with oMLX." : "Apple Intelligence, running on this iPhone.")
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .navigationTitle("oMLX Demo")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Model", selection: $chat.backend) {
                        ForEach(Backend.allCases) { backend in
                            Label(backend.rawValue, systemImage: backend.systemImage)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        chat.startOver()
                    }
                    .disabled(chat.turns.isEmpty)
                }
            }
            .safeAreaBar(edge: .bottom) {
                composer
            }
            .sheet(isPresented: $isShowingSettings, onDismiss: { chat.reconnectIfNeeded() }) {
                SettingsView()
            }
            .task {
                if Keychain.apiKey == nil {
                    isShowingSettings = true
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding()
                .glassEffect(.regular.interactive())

            if chat.isResponding {
                Button("Stop", systemImage: "stop.fill") {
                    chat.stop()
                }
            } else {
                Button("Send", systemImage: "arrow.up") {
                    send()
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding()
    }

    private func send() {
        chat.send(draft)
        draft = ""
    }
}

/// A prompt, the model's thinking, and its answer.
struct TurnSection: View {
    let turn: Turn

    var body: some View {
        Section {
            Text(turn.prompt)
                .font(.headline)

            if !turn.reasoning.isEmpty {
                DisclosureGroup("Thinking") {
                    Text(turn.reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !turn.response.isEmpty {
                Text(AttributedString(blockMarkdown: turn.response))
                    .textSelection(.enabled)
            } else if !turn.isComplete {
                ProgressView()
            }

            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } footer: {
            if let speed = turn.tokensPerSecond, let firstToken = turn.timeToFirstToken {
                Text("\(speed, format: .number.precision(.fractionLength(0))) tokens/s · first token in \(firstToken, format: .number.precision(.fractionLength(1))) s")
            }
        }
    }
}

#Preview {
    ChatView()
}

#Preview("Formatted answer") {
    var turn = Turn(prompt: "How can I make local inference faster?")
    turn.response = """
        A 27B model is limited by memory bandwidth.
        Batching spreads that cost across requests.

        - Use **4-bit** weights
        - Turn on `Lightning MTP`
            1. Nested step

        ## Next
        Try a smaller draft model.
        """
    turn.reasoning = "Thinking about bandwidth."
    turn.tokensPerSecond = 33.8
    turn.timeToFirstToken = 0.4
    turn.isComplete = true
    return List { TurnSection(turn: turn) }
}
