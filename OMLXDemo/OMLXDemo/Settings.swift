import Foundation
import FoundationModels
import Security
import SwiftUI

/// UserDefaults keys shared by the settings screen and the chat.
enum SettingsKey {
    static let serverURL = "serverURL"
    static let modelName = "modelName"
    static let reasoning = "reasoning"
}

/// How to reach oMLX on the Mac.
struct Connection: Equatable {
    static let defaultURL = "http://localhost:8000/v1"
    static let defaultModel = "Qwen3.8-27B-oQ4e-mtp"

    var url: String
    var model: String
    var apiKey: String?

    static var current: Connection {
        let defaults = UserDefaults.standard
        return Connection(
            url: defaults.string(forKey: SettingsKey.serverURL) ?? defaultURL,
            model: defaults.string(forKey: SettingsKey.modelName) ?? defaultModel,
            apiKey: Keychain.apiKey
        )
    }
}

/// How much the Mac's model thinks before answering.
enum Reasoning: String, CaseIterable, Identifiable {
    case automatic, off, light, moderate, deep

    var id: Self { self }

    static var current: Reasoning {
        UserDefaults.standard.string(forKey: SettingsKey.reasoning).flatMap(Reasoning.init(rawValue:)) ?? .automatic
    }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .off: "Off"
        case .light: "Light"
        case .moderate: "Moderate"
        case .deep: "Deep"
        }
    }

    var level: ContextOptions.ReasoningLevel? {
        switch self {
        case .automatic: nil
        case .off: .custom("none")
        case .light: .light
        case .moderate: .moderate
        case .deep: .deep
        }
    }
}

/// Stores the oMLX API key in the Keychain, on this device only.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "OMLXDemo",
        kSecAttrAccount as String: "oMLX API key",
    ]

    static var apiKey: String? {
        get {
            var search = query
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(newValue.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
