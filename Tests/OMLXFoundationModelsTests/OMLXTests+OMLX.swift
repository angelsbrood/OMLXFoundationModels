import Foundation
import FoundationModels
@testable import OMLXFoundationModels
import Testing

// Tests for behavior this fork adds on top of upstream.
extension OMLXTests {
  @Suite struct OMLX {
    init() { MockSSEProtocol.reset() }

    // MARK: Authentication

    @Test func `sends the API key as a bearer token`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel(apiKey: "omlx-test"))
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer omlx-test")
    }

    @Test func `an explicit Authorization header wins over the API key`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let model = makeMockModel(headers: ["Authorization": "Bearer explicit"], apiKey: "ignored")
      let session = LanguageModelSession(model: model)
      let _ = try await session.respond(to: "test")

      let request = try capturedRequest()
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer explicit")
    }

    // MARK: Reasoning

    @Test func `omits thinking controls when no reasoning level is set`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let body = try requestBody()
      #expect(body["reasoning_effort"] == nil)
      #expect(body["enable_thinking"] == nil)
    }

    @Test(arguments: [
      (ContextOptions.ReasoningLevel.light, "low"),
      (.moderate, "medium"),
      (.deep, "high"),
      (.custom("xhigh"), "xhigh"),
    ])
    func `maps reasoning levels to reasoning_effort`(
      level: ContextOptions.ReasoningLevel,
      effort: String
    ) async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: Prompt { "test" },
        contextOptions: ContextOptions(includeSchemaInPrompt: nil, reasoningLevel: level)
      )

      let body = try requestBody()
      #expect(body["reasoning_effort"] as? String == effort)
      #expect(body["enable_thinking"] as? Bool == true)
    }

    @Test func `custom none turns thinking off`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: Prompt { "test" },
        contextOptions: ContextOptions(includeSchemaInPrompt: nil, reasoningLevel: .custom("none"))
      )

      let body = try requestBody()
      #expect(body["reasoning_effort"] == nil)
      #expect(body["enable_thinking"] as? Bool == false)
    }

    // MARK: Sampling

    @Test func `greedy sampling sends temperature zero`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "test",
        options: GenerationOptions(sampling: .greedy, temperature: 0.7)
      )

      let body = try requestBody()
      #expect(body["temperature"] as? Double == 0)
      #expect(body["top_p"] == nil)
    }

    @Test func `top-k sampling sends top_k and seed`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "test",
        options: GenerationOptions(sampling: .random(top: 20, seed: 7), temperature: 0.6)
      )

      let body = try requestBody()
      #expect(body["top_k"] as? Int == 20)
      #expect(body["seed"] as? Int == 7)
      #expect(body["temperature"] as? Double == 0.6)
    }

    @Test func `nucleus sampling sends top_p and seed`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("OK")) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "test",
        options: GenerationOptions(sampling: .random(probabilityThreshold: 0.95, seed: 3))
      )

      let body = try requestBody()
      #expect(body["top_p"] as? Double == 0.95)
      #expect(body["seed"] as? Int == 3)
    }

    // MARK: Errors

    @Test func `maps context overflow to contextSizeExceeded`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          400,
          Data(
            #"{"error":{"message":"Prompt is too long: 270000 tokens > 262144 maximum context length","type":"invalid_request_error","param":null,"code":"context_length_exceeded"}}"#
              .utf8
          )
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      do {
        let _ = try await session.respond(to: "test")
        Issue.record("Expected contextSizeExceeded")
      } catch LanguageModelError.contextSizeExceeded(let context) {
        #expect(context.tokenCount == 270_000)
        #expect(context.contextSize == 262_144)
      }
    }

    @Test func `maps a full queue to rateLimited with a reset date`() async throws {
      MockSSEProtocol.responseHeaders = ["Retry-After": "1"]
      MockSSEProtocol.handler = { _ in
        (
          503,
          Data(
            #"{"error":{"message":"Scheduler waiting queue full (8/8). Try again shortly.","type":"server_error","param":null,"code":null}}"#
              .utf8
          )
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      do {
        let _ = try await session.respond(to: "test")
        Issue.record("Expected rateLimited")
      } catch LanguageModelError.rateLimited(let limit) {
        #expect(limit.resetDate != nil)
      }
    }

    @Test func `surfaces the server message for other errors`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          401,
          Data(
            #"{"error":{"message":"Invalid API key","type":"authentication_error","param":null,"code":null}}"#
              .utf8
          )
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      do {
        let _ = try await session.respond(to: "test")
        Issue.record("Expected an API error")
      } catch let error as OMLXLanguageModel.APIError {
        #expect(error.message == "Invalid API key")
        #expect(error.localizedDescription == "Invalid API key")
      }
    }

    // MARK: Streaming

    @Test func `ignores empty keep-alive deltas`() async throws {
      let sseData = Data(
        [
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"role":"assistant","content":""}}]}"#,
          "",
          ": keep-alive",
          "",
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"Hi"}}]}"#,
          "",
          "data: [DONE]",
          "",
        ].joined(separator: "\n").utf8
      )
      MockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "Hi")
    }

    @Test func `drops blank lines before the first visible text`() async throws {
      let sseData = Data(
        [
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"reasoning_content":"\nLet me think."}}]}"#,
          "",
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"\n\n"}}]}"#,
          "",
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"Hello!\n\nBye."}}]}"#,
          "",
          "data: [DONE]",
          "",
        ].joined(separator: "\n").utf8
      )
      MockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      #expect(session.transcript.responseText == "Hello!\n\nBye.")
      let reasoning = session.transcript.compactMap(\.reasoning).first?.segments
        .compactMap { segment -> String? in
          if case .text(let text) = segment { return text.content }
          return nil
        }
        .joined()
      #expect(reasoning == "Let me think.")
    }

    @Test func `attaches oMLX timing to response metadata`() async throws {
      let sseData = Data(
        [
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"Hi"}}]}"#,
          "",
          #"data: {"id":"1","model":"Qwen3.8-27B-oQ4e-mtp","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":1,"total_tokens":13,"time_to_first_token":0.25,"prompt_tokens_per_second":420.5,"generation_tokens_per_second":33.8}}"#,
          "",
          "data: [DONE]",
          "",
        ].joined(separator: "\n").utf8
      )
      MockSSEProtocol.handler = { _ in (200, sseData) }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(to: "test")

      let metadata = try #require(session.transcript.compactMap(\.response).last?.metadata)
      let speed = try metadata[OMLXLanguageModel.MetadataKey.generationTokensPerSecond]?
        .value(Double.self)
      let firstToken = try metadata[OMLXLanguageModel.MetadataKey.timeToFirstToken]?
        .value(Double.self)
      let model = try metadata[OMLXLanguageModel.MetadataKey.model]?.value(String.self)
      #expect(speed == 33.8)
      #expect(firstToken == 0.25)
      #expect(model == "Qwen3.8-27B-oQ4e-mtp")
    }
  }
}
