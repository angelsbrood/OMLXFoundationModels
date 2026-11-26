import Foundation
import FoundationModels
@testable import OMLXFoundationModels
import Security
import Testing

extension OMLXTests {
  /// Live tests against a running oMLX server.
  ///
  /// ```
  /// OMLX_TEST_ENDPOINT=http://127.0.0.1:8000/v1 \
  /// OMLX_TEST_API_KEY=<your key> \
  /// swift test --filter Live
  /// ```
  ///
  /// `OMLX_TEST_MODEL` defaults to `Qwen3.8-27B-oQ4e-mtp`. Instead of
  /// `OMLX_TEST_API_KEY`, `OMLX_TEST_KEYCHAIN_SERVICE` names a Keychain item
  /// to read the key from, whose account is the endpoint's `host:port`. That
  /// keeps the key out of the scheme.
  @Suite(
    "Live",
    .enabled(
      if: ProcessInfo.processInfo.environment["OMLX_TEST_ENDPOINT"] != nil,
      "Set OMLX_TEST_ENDPOINT to run."
    )
  )
  struct Live {
    @Generable
    struct City {
      @Guide(description: "The city's name")
      var name: String
      @Guide(description: "The country the city is in")
      var country: String
    }

    let model: OMLXLanguageModel

    init() throws {
      let environment = ProcessInfo.processInfo.environment
      let url = try #require(environment["OMLX_TEST_ENDPOINT"].flatMap(URL.init(string:)))
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 300
      model = OMLXLanguageModel(
        name: environment["OMLX_TEST_MODEL"] ?? "Qwen3.8-27B-oQ4e-mtp",
        url: url,
        apiKey: environment["OMLX_TEST_API_KEY"]
          ?? environment["OMLX_TEST_KEYCHAIN_SERVICE"].flatMap { Self.storedKey(service: $0, for: url) },
        urlSessionConfiguration: configuration
      )
    }

    // Inkling 2 thinks whatever it's told, so this one needs a model that
    // can stop, such as Qwen.
    @Test func `answers without thinking`() async throws {
      let session = LanguageModelSession(model: model)
      let response = try await session.respond(
        to: Prompt { "Reply with one short greeting." },
        contextOptions: ContextOptions(includeSchemaInPrompt: nil, reasoningLevel: .custom("none"))
      )

      #expect(!response.content.isEmpty)
      #expect(session.transcript.compactMap(\.reasoning).isEmpty)
      let speed = try session.transcript.compactMap(\.response).last?
        .metadata[OMLXLanguageModel.MetadataKey.generationTokensPerSecond]?
        .value(Double.self)
      #expect(speed != nil)
      print("[Live] \(response.content) — \(speed ?? 0) tok/s")
    }

    @Generable
    struct Verdict {
      @Guide(description: "Whether the claim is true")
      var isTrue: Bool
      @Guide(description: "One sentence on why")
      var reason: String
    }

    // With `.afterReasoning` the model reasons before it answers, whatever
    // oMLX does with a grammar. (Inkling 2 skips its reasoning under one.)
    @Test func `thinks before a Generable value`() async throws {
      var model = model
      model.structuredOutput = .afterReasoning
      let session = LanguageModelSession(model: model)
      let response = try await session.respond(
        to: "Is 1,001 a prime number?",
        generating: Verdict.self
      )

      let reasoning = session.transcript.compactMap(\.reasoning)
      #expect(!reasoning.isEmpty)
      #expect(response.usage.output.reasoningTokenCount > 0)
      #expect(response.content.isTrue == false)
      print(
        "[Live] \(response.content.isTrue): \(response.content.reason)",
        "(\(response.usage.output.reasoningTokenCount) reasoning tokens)"
      )
    }

    @Test func `generates a Generable value`() async throws {
      let session = LanguageModelSession(model: model)
      let response = try await session.respond(
        to: "Name the capital of Japan.",
        generating: City.self
      )

      #expect(response.content.name.localizedCaseInsensitiveContains("Tokyo"))
      #expect(response.content.country.localizedCaseInsensitiveContains("Japan"))
    }

    /// The key in the Keychain item for `url`'s `host:port`.
    private static func storedKey(service: String, for url: URL) -> String? {
      let host = url.host() ?? url.absoluteString
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: url.port.map { "\(host):\($0)" } ?? host,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
        let data = item as? Data
      else {
        return nil
      }
      return String(decoding: data, as: UTF8.self)
    }
  }
}
