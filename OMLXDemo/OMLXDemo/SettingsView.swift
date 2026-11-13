import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.serverURL) private var serverURL = Connection.defaultURL
    @AppStorage(SettingsKey.modelName) private var modelName = Connection.defaultModel
    @AppStorage(SettingsKey.reasoning) private var reasoning = Reasoning.automatic
    @State private var apiKey = Keychain.apiKey ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        LabeledContent("Server") {
                            TextField("Server", text: $serverURL, prompt: Text(verbatim: Connection.defaultURL))
                                .keyboardType(.URL)
                                .textContentType(.URL)
                        }
                        LabeledContent("Model") {
                            TextField("Model", text: $modelName, prompt: Text(verbatim: Connection.defaultModel))
                        }
                        LabeledContent("API Key") {
                            SecureField("API Key", text: $apiKey, prompt: Text("Required"))
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("oMLX")
                } footer: {
                    Text("On iPhone, use your Mac’s local hostname, like http://name.local:8000/v1. The key is kept in this device’s Keychain.")
                }

                Section {
                    Picker("Reasoning", selection: $reasoning) {
                        ForEach(Reasoning.allCases) { option in
                            Text(option.title)
                        }
                    }
                } footer: {
                    Text("How long Qwen thinks before it answers.")
                }
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        dismiss()
                    }
                }
            }
            .onChange(of: apiKey) {
                Keychain.apiKey = apiKey
            }
        }
    }
}

#Preview {
    SettingsView()
}
