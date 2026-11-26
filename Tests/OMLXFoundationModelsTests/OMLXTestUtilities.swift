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
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FoundationModels
@testable import OMLXFoundationModels
import Testing

func makeMockModel(
  name: String = "test-model",
  url: URL = URL(string: "https://mock-llm.test/v1")!,
  headers: [String: String] = [:],
  apiKey: String? = nil,
  supportsGuidedGeneration: Bool = true,
  structuredOutput: OMLXLanguageModel.StructuredOutput = .grammar
) -> OMLXLanguageModel {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockSSEProtocol.self]
  var model = OMLXLanguageModel(
    name: name,
    url: url,
    apiKey: apiKey,
    additionalHeaders: headers,
    supportsGuidedGeneration: supportsGuidedGeneration,
    structuredOutput: structuredOutput
  )
  model.urlSession = URLSession(configuration: config)
  return model
}

func capturedRequest() throws -> URLRequest {
  try #require(MockSSEProtocol.lastRequest)
}

func requestBody() throws -> [String: Any] {
  let request = try capturedRequest()
  let body = try #require(request.httpBody)
  return try JSONSerialization.jsonObject(with: body) as! [String: Any]
}

extension Transcript {
  var responseText: String {
    compactMap(\.response)
      .flatMap(\.segments)
      .compactMap { segment -> String? in
        if case .text(let text) = segment { return text.content }
        return nil
      }
      .joined()
  }
}
