import Foundation
import FoundationModels
@testable import OMLXFoundationModels
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
  /// `OMLX_TEST_MODEL` defaults to `Qwen3.8-27B-oQ4e-mtp`.
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
        apiKey: environment["OMLX_TEST_API_KEY"],
        urlSessionConfiguration: configuration
      )
    }

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

    @Test func `generates a Generable value`() async throws {
      let session = LanguageModelSession(model: model)
      let response = try await session.respond(
        to: "Name the capital of Japan.",
        generating: City.self
      )

      #expect(response.content.name.localizedCaseInsensitiveContains("Tokyo"))
      #expect(response.content.country.localizedCaseInsensitiveContains("Japan"))
    }
  }
}
