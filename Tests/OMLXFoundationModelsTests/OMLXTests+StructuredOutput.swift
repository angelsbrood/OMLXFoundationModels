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
