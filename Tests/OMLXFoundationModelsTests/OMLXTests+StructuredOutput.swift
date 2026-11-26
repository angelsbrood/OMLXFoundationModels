//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
//
// Modified in 2026 for oMLX: adapted to OMLXLanguageModel.
//
//===----------------------------------------------------------------------===//
#if canImport(Darwin)
import Foundation
import FoundationModels
@testable import OMLXFoundationModels
import Testing

extension OMLXTests {
  @Suite struct StructuredOutput {
    init() { MockSSEProtocol.reset() }

    @Generable
    struct MockWeatherInfo {
      var temperature: Int
      var condition: String
    }

    @Test func `parses structured JSON response into Generable type`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          200,
          MockSSE.text(
            #"{"temperature":"#,
            #"72,"#,
            #""condition":"#,
            #""sunny"}"#
          )
        )
      }

      let session = LanguageModelSession(model: makeMockModel())
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      #expect(response.content.temperature == 72)
      #expect(response.content.condition == "sunny")
    }

    // oMLX: structured output goes in `structured_outputs`, not `response_format`.
    @Test func `includes structured outputs in request for structured output`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.text(#"{"temperature":65,"condition":"cloudy"}"#))
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      let body = try requestBody()
      #expect(body["response_format"] == nil)

      let structuredOutputs = body["structured_outputs"] as? [String: Any]
      let jsonSchema = structuredOutputs?["json"] as? [String: Any]
      #expect(jsonSchema != nil)
    }

    // oMLX: the schema is also described in the latest user message.
    @Test func `describes schema in the latest user message by default`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.text(#"{"temperature":65,"condition":"cloudy"}"#))
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      let body = try requestBody()
      let messages = try #require(body["messages"] as? [[String: Any]])
      let user = try #require(messages.last { $0["role"] as? String == "user" })
      let parts = try #require(user["content"] as? [[String: Any]])
      #expect(parts.count == 2)
      #expect(parts.first?["text"] as? String == "Weather?")
      let instruction = try #require(parts.last?["text"] as? String)
      #expect(instruction.contains("JSON Schema"))
      #expect(instruction.contains("condition"))
    }

    @Test func `omits schema description when includeSchemaInPrompt is false`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.text(#"{"temperature":65,"condition":"cloudy"}"#))
      }

      let session = LanguageModelSession(model: makeMockModel())
      let _ = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self,
        includeSchemaInPrompt: false
      )

      let body = try requestBody()
      let messages = try #require(body["messages"] as? [[String: Any]])
      let user = try #require(messages.last { $0["role"] as? String == "user" })
      #expect(user["content"] as? String == "Weather?")
    }

    // oMLX: with `.afterReasoning`, there's no grammar: the model reasons,
    // then answers in words, and the JSON is read from its answer.
    @Test func `after reasoning, the answer's JSON is read from what the model writes`() async throws {
      MockSSEProtocol.handler = { _ in
        (
          200,
          MockSSE.chunks([
            .init(reasoning: "Warm and clear today, "),
            .init(reasoning: "so 72 and sunny."),
            .init(text: "Here's the weather:\n```json\n{\"temperature\": 72, "),
            .init(text: "\"condition\": \"sunny\"}\n```\nEnjoy {it}!"),
            .init(usage: .init(promptTokens: 40, completionTokens: 30, reasoningTokens: 12)),
          ])
        )
      }

      let session = LanguageModelSession(model: makeMockModel(structuredOutput: .afterReasoning))
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self,
        includeSchemaInPrompt: false
      )

      #expect(response.content.temperature == 72)
      #expect(response.content.condition == "sunny")
      #expect(session.transcript.compactMap(\.reasoning).count == 1)
      #expect(response.usage.output.totalTokenCount == 30)
      #expect(response.usage.output.reasoningTokenCount == 12)

      let body = try requestBody()
      #expect(body["structured_outputs"] == nil)
      // Without a grammar the prompt is all the model has, so the schema is
      // described even though the caller turned that off.
      let messages = try #require(body["messages"] as? [[String: Any]])
      let user = try #require(messages.last { $0["role"] as? String == "user" })
      let parts = try #require(user["content"] as? [[String: Any]])
      #expect((parts.last?["text"] as? String)?.contains("JSON Schema") == true)
    }

    @Test func `after reasoning, a request with reasoning off gets the grammar`() async throws {
      MockSSEProtocol.handler = { _ in
        (200, MockSSE.text(#"{"temperature":65,"condition":"cloudy"}"#))
      }

      let session = LanguageModelSession(model: makeMockModel(structuredOutput: .afterReasoning))
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self,
        contextOptions: ContextOptions(reasoningLevel: .custom("none"))
      )

      #expect(response.content.condition == "cloudy")
      let body = try requestBody()
      #expect(body["structured_outputs"] != nil)
    }

    @Test func `after reasoning, an answer without JSON is an error`() async throws {
      MockSSEProtocol.handler = { _ in (200, MockSSE.text("It's sunny, about 72.")) }

      let session = LanguageModelSession(model: makeMockModel(structuredOutput: .afterReasoning))
      let error = await #expect(throws: OMLXLanguageModel.RequestError.self) {
        try await session.respond(to: "Weather?", generating: MockWeatherInfo.self)
      }
      guard case .answerWithoutJSON(let answer)? = error else {
        Issue.record("Expected answerWithoutJSON, got \(String(describing: error))")
        return
      }
      #expect(answer == "It's sunny, about 72.")
    }

    @Test func `after reasoning, an answer cut short by the token limit says so`() async throws {
      MockSSEProtocol.handler = { _ in
        let lines = [
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"reasoning_content":"Thinking it over, at length"}}]}"#,
          "",
          #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"So the "},"finish_reason":"length"}]}"#,
          "",
          "data: [DONE]",
          "",
        ]
        return (200, Data(lines.joined(separator: "\n").utf8))
      }

      let session = LanguageModelSession(model: makeMockModel(structuredOutput: .afterReasoning))
      let error = await #expect(throws: OMLXLanguageModel.RequestError.self) {
        try await session.respond(
          to: "Weather?", generating: MockWeatherInfo.self,
          options: GenerationOptions(maximumResponseTokens: 64))
      }
      guard case .answerCutShort(let answer)? = error else {
        Issue.record("Expected answerCutShort, got \(String(describing: error))")
        return
      }
      #expect(answer == "So the ")
      #expect(error?.localizedDescription.contains("maximumResponseTokens") == true)
    }

    @Test(arguments: [
      (#"{"a": 1}"#, #"{"a": 1}"#),
      (#"First {"draft": true}, then {"a": {"b": [1, 2]}}."#, #"{"a": {"b": [1, 2]}}"#),
      (#"A brace { left open. {"a": "}"}"#, #"{"a": "}"}"#),
      (#"[1, 2, 3]"#, #"[1, 2, 3]"#),
      ("true", "true"),
      (#"  "senior"  "#, #""senior""#),
    ])
    func `reads the last JSON value in an answer`(answer: String, json: String) {
      #expect(OMLXLanguageModel.Executor.lastJSONValue(in: answer) == json)
    }

    @Test func `finds no JSON in prose`() {
      #expect(OMLXLanguageModel.Executor.lastJSONValue(in: "It's sunny {probably}.") == nil)
    }

    @Test func `parses structured output from single-character chunks`() async throws {
      let json = #"{"temperature":99,"condition":"hot"}"#

      MockSSEProtocol.handler = { _ in
        var lines = [String]()
        for char in json {
          let chunk = String(char)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
          lines.append(
            #"data: {"id":"1","model":"mock","choices":[{"delta":{"content":"\#(chunk)"}}]}"#
          )
          lines.append("")
        }
        lines.append("data: [DONE]")
        return (200, Data(lines.joined(separator: "\n").utf8))
      }

      let session = LanguageModelSession(model: makeMockModel())
      let response = try await session.respond(
        to: "Weather?",
        generating: MockWeatherInfo.self
      )

      #expect(response.content.temperature == 99)
      #expect(response.content.condition == "hot")
    }
  }
}
#endif
