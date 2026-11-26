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
// Modified in 2026 for oMLX. Forked from ChatCompletionsLanguageModel.swift in
// apple/foundation-models-utilities 1.1.0. Every change from upstream is
// marked with an `oMLX:` comment so the fork can be rebased onto new releases.
//
//===----------------------------------------------------------------------===//
public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif
public import FoundationModels
#if canImport(CoreImage)
private import CoreImage
private import UniformTypeIdentifiers
#endif

// oMLX: renamed from `ChatCompletionsLanguageModel`.
/// A `LanguageModel` backed by an [oMLX](https://github.com/jundot/omlx)
/// server, streaming results back through the Foundation Models framework.
///
/// oMLX speaks the OpenAI Chat Completions API, plus extensions this model
/// uses: reasoning controls, top-k sampling, seeds, strict grammar-enforced
/// structured output, and per-request timing.
///
/// ```swift
/// let model = OMLXLanguageModel(
///     name: "Qwen3.8-27B-oQ4e-mtp",
///     url: URL(string: "http://my-mac.local:8000/v1")!,
///     apiKey: apiKey
/// )
///
/// let session = LanguageModelSession(model: model)
/// let response = try await session.respond(to: "Hello!")
/// ```
public struct OMLXLanguageModel: Sendable, LanguageModel {
  /// The name of the underlying model, sent in the `model` field of each
  /// chat completion request.
  public var name: String

  /// The base URL of the chat completions endpoint. The path
  /// `/v1/chat/completions` is appended automatically when the supplied
  /// URL does not already include a version segment matching `v<digits>`
  /// (for example `v1`, `v2`, or `v3`). When a version segment is
  /// present, only `/chat/completions` is appended.
  public var url: URL

  /// Headers added to every outgoing request, merged on top of the
  /// defaults. Use this to provide authorization tokens or other
  /// vendor-specific headers.
  public var additionalHeaders: [String: String]

  public var supportsGuidedGeneration: Bool

  // oMLX: how a `Generable` answer is made to fit its schema.
  /// How oMLX makes a response fit a `Generable` type.
  public var structuredOutput: StructuredOutput

  // Overridden in tests to inject a URLSession with mock protocol handlers.
  var urlSession: URLSession?

  /// Creates an oMLX language model.
  ///
  /// - Parameters:
  ///   - name: The model identifier sent in the `model` field of each
  ///     request, as oMLX lists it.
  ///   - url: The base URL of the oMLX server, for example
  ///     `http://my-mac.local:8000/v1`.
  ///   - apiKey: An oMLX API key, sent as a bearer token. Prefer one of
  ///     oMLX's API-only keys so you can revoke it on its own.
  ///   - additionalHeaders: Headers to merge on top of the defaults.
  ///   - supportsGuidedGeneration: Whether to declare guided generation.
  ///     Defaults to `true`; oMLX enforces schemas with a grammar.
  ///   - structuredOutput: How oMLX makes a response fit a `Generable`
  ///     type. Defaults to ``StructuredOutput/grammar``; use
  ///     ``StructuredOutput/afterReasoning`` for models that skip their
  ///     reasoning under a grammar, such as Inkling 2.
  ///   - urlSessionConfiguration: An optional `URLSessionConfiguration` used
  ///     to build the `URLSession` that drives requests. Use this to tune
  ///     timeouts, proxies, or other transport settings. When `nil`, an
  ///     ephemeral configuration is used.
  public init(
    name: String,
    url: URL,
    apiKey: String? = nil,
    additionalHeaders: [String: String] = [:],
    supportsGuidedGeneration: Bool = true,
    structuredOutput: StructuredOutput = .grammar,
    urlSessionConfiguration: URLSessionConfiguration? = nil
  ) {
    self.name = name
    self.url = url
    // oMLX: oMLX authenticates with a bearer token. An explicit
    // `Authorization` header still wins.
    var headers = additionalHeaders
    if let apiKey, !apiKey.isEmpty, headers["Authorization"] == nil {
      headers["Authorization"] = "Bearer \(apiKey)"
    }
    self.additionalHeaders = headers
    self.supportsGuidedGeneration = supportsGuidedGeneration
    self.structuredOutput = structuredOutput
    self.urlSession = urlSessionConfiguration.map { URLSession(configuration: $0) }
  }

  // Implementation of LanguageModel Protocol
  public var capabilities: LanguageModelCapabilities {
    if supportsGuidedGeneration {
      LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
    } else {
      LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
    }
  }

  public var executorConfiguration: Executor.Configuration {
    Executor.Configuration(
      modelName: name,
      url: url,
      additionalHeaders: additionalHeaders,
      structuredOutput: structuredOutput,
      urlSession: urlSession
    )
  }

  // oMLX: a reasoning model that oMLX frames properly thinks before a
  // grammar-constrained answer. Inkling 2 doesn't: under a grammar it skips
  // its reasoning at every level and writes a worse answer.
  /// How oMLX makes a response fit a `Generable` type.
  public enum StructuredOutput: Hashable, Sendable {
    /// oMLX constrains the answer with a grammar compiled from the schema, so
    /// it always fits. Reasoning models that oMLX frames for it, such as
    /// Qwen, still think first.
    case grammar

    /// The model reads the schema in the prompt, reasons as it would about
    /// any question, then writes its answer, and the answer's JSON is taken
    /// from what it wrote. For models that skip their reasoning under a
    /// grammar, such as Inkling 2. The answer arrives whole, once the model
    /// has finished; its reasoning still streams. A request that turns
    /// reasoning off gets the grammar.
    case afterReasoning
  }

  // oMLX: keys for the server-reported timing that this model attaches to
  // each response entry's metadata.
  /// Keys for values this model adds to `Transcript.Response.metadata`.
  ///
  /// ```swift
  /// let speed = try? response.metadata[OMLXLanguageModel.MetadataKey.generationTokensPerSecond]?
  ///   .value(Double.self)
  /// ```
  public enum MetadataKey {
    /// The model that produced the response, as oMLX reports it (`String`).
    public static let model = "omlx.model"
    /// Seconds from request to first generated token (`Double`).
    public static let timeToFirstToken = "omlx.timeToFirstToken"
    /// Prompt processing speed in tokens per second (`Double`).
    public static let promptTokensPerSecond = "omlx.promptTokensPerSecond"
    /// Generation speed in tokens per second (`Double`).
    public static let generationTokensPerSecond = "omlx.generationTokensPerSecond"
  }

  // oMLX: a request's metadata can carry options that `GenerationOptions`
  // has no place for.
  /// Keys a request's metadata can hold to steer this model.
  ///
  /// ```swift
  /// let response = try await session.respond(
  ///   to: listing, generating: Verdict.self,
  ///   metadata: [OMLXLanguageModel.RequestKey.seed: 42]
  /// )
  /// ```
  public enum RequestKey {
    /// A seed for this request's sampling (`Int`), so the same request gets
    /// the same answer, sampled with the server's own settings. A
    /// `GenerationOptions` sampling mode carries a seed only with top-k or
    /// nucleus settings of its own; when it has one, it's used instead.
    public static let seed = "omlx.seed"
  }

  /// An error returned by the chat completions endpoint in the body of a
  /// failed request or a streaming error event.
  ///
  /// Servers may populate any subset of the optional fields.
  public struct APIError: LocalizedError {
    /// A human-readable explanation of the error returned by the server.
    public var message: String

    /// The error category reported by the server (for example,
    /// `"invalid_request_error"`).
    public var type: String?

    /// The name of the request parameter associated with the error,
    /// when applicable.
    public var param: String?

    /// A short machine-readable error code provided by the server.
    public var code: String?

    // oMLX: keep the status, so a caller can tell a failure worth retrying,
    // such as a 500 from a model evicted mid-request, from one that isn't.
    /// The HTTP status code, or `nil` for an error the server sent in the
    /// body of a reply already under way.
    public var statusCode: Int?

    /// Creates a new API error.
    ///
    /// - Parameters:
    ///   - message: A human-readable explanation of the error.
    ///   - type: The error category reported by the server.
    ///   - param: The request parameter associated with the error.
    ///   - code: A short machine-readable error code.
    ///   - statusCode: The HTTP status code.
    public init(
      message: String,
      type: String? = nil,
      param: String? = nil,
      code: String? = nil,
      statusCode: Int? = nil
    ) {
      self.message = message
      self.statusCode = statusCode
      self.type = type
      self.param = param
      self.code = code
    }

    // oMLX: show the server's message instead of a generic description.
    public var errorDescription: String? { message }
  }

  /// An error raised by ``OMLXLanguageModel`` when a request
  /// cannot be issued or its response cannot be parsed.
  public enum RequestError: LocalizedError {
    /// The request could not be constructed because of invalid input.
    /// The associated value contains a human-readable description.
    case invalidRequest(_ description: String)

    /// A streaming chunk could not be decoded as a chat completion event.
    case invalidStreamData

    /// The endpoint returned a non-200 HTTP status code. The associated
    /// values contain the status code and the raw response body.
    case httpError(statusCode: Int, data: Data)

    // oMLX: with `StructuredOutput.afterReasoning`, the answer must contain
    // the JSON it's read from.
    /// With ``OMLXLanguageModel/StructuredOutput/afterReasoning``, the
    /// model's answer had no JSON in it. The associated value is the answer.
    case answerWithoutJSON(_ answer: String)

    /// With ``OMLXLanguageModel/StructuredOutput/afterReasoning``, the model
    /// ran out of response tokens before it wrote its JSON, often while it
    /// was still reasoning. Raise `GenerationOptions.maximumResponseTokens`.
    /// The associated value is the answer so far.
    case answerCutShort(_ answer: String)

    public var errorDescription: String? {
      switch self {
      case .invalidRequest(let description):
        "Invalid request: \(description)"
      case .invalidStreamData:
        "Invalid streaming data received"
      case .httpError(let statusCode, let data):
        """
        HTTP error with status code \(statusCode):
        \(String(data: data, encoding: .utf8) ?? data.description)
        """
      case .answerWithoutJSON(let answer):
        "The model's answer had no JSON in it: \(answer.prefix(300))"
      case .answerCutShort:
        "The model ran out of response tokens before it answered. Raise maximumResponseTokens."
      }
    }
  }

  /// The wire format of an error envelope returned by the chat completions
  /// endpoint, used internally to decode error responses before raising
  /// them as ``APIError``.
  struct ErrorResponse: Codable, Sendable {
    var error: APIError

    struct APIError: Codable, Sendable {
      var message: String
      var type: String?
      var param: String?
      var code: String?
    }
  }

  // oMLX: translate oMLX's error envelopes into the framework's typed errors,
  // so apps can match `.contextSizeExceeded` and `.rateLimited`.
  static func mappedError(statusCode: Int?, body: Data, retryAfter: String? = nil) -> any Error {
    let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: body)
    let message = envelope?.error.message ?? String(decoding: body, as: UTF8.self)

    // oMLX reports "Prompt is too long: <tokens> tokens > <limit> maximum
    // context length" with the OpenAI `context_length_exceeded` code.
    if envelope?.error.code == "context_length_exceeded"
      || message.localizedCaseInsensitiveContains("maximum context length")
    {
      let numbers = message.matches(of: #/\d+/#).compactMap { Int($0.output) }
      return LanguageModelError.contextSizeExceeded(
        LanguageModelError.ContextSizeExceeded(
          contextSize: numbers.count > 1 ? numbers[1] : 0,
          tokenCount: numbers.first ?? 0,
          debugDescription: message
        )
      )
    }

    // 429, or 503 when oMLX's request queue is full (it sends Retry-After).
    if statusCode == 429 || statusCode == 503 {
      return LanguageModelError.rateLimited(
        LanguageModelError.RateLimited(
          resetDate: retryAfter.flatMap { TimeInterval($0) }.map { Date.now.addingTimeInterval($0) },
          debugDescription: message
        )
      )
    }

    if let envelope {
      return APIError(
        message: envelope.error.message,
        type: envelope.error.type,
        param: envelope.error.param,
        code: envelope.error.code,
        statusCode: statusCode
      )
    }
    if let statusCode {
      return RequestError.httpError(statusCode: statusCode, data: body)
    }
    return RequestError.invalidStreamData
  }

  public struct Executor: LanguageModelExecutor {
    public typealias Model = OMLXLanguageModel
    private let configuration: Configuration

    public init(configuration: Configuration) {
      self.configuration = configuration
    }

    public struct Configuration: Hashable, Sendable {
      fileprivate let modelName: String
      fileprivate let url: URL
      fileprivate let additionalHeaders: [String: String]
      fileprivate let structuredOutput: StructuredOutput
      fileprivate let urlSession: URLSession?

      public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
        lhs.modelName == rhs.modelName
          && lhs.url == rhs.url
          && lhs.additionalHeaders == rhs.additionalHeaders
          && lhs.structuredOutput == rhs.structuredOutput
      }

      public func hash(into hasher: inout Hasher) {
        hasher.combine(modelName)
        hasher.combine(url)
        hasher.combine(additionalHeaders)
        hasher.combine(structuredOutput)
      }
    }

    // oMLX: factored out of `respond` so `prewarm` can share it.
    private func makeClient() -> ChatCompletionsClient {
      // Caller-supplied headers override the defaults on conflict.
      let headers = [
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "User-Agent": Bundle.main.bundleIdentifier ?? "com.apple.FoundationModels"
      ].merging(
        configuration.additionalHeaders,
        uniquingKeysWith: { _, custom in custom }
      )

      // Tests inject a URLSession; production uses a fresh ephemeral one.
      return ChatCompletionsClient(
        baseURL: configuration.url,
        headers: headers,
        session: configuration.urlSession ?? URLSession(configuration: .ephemeral)
      )
    }

    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: OMLXLanguageModel,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      let client = makeClient()

      var messages = try convertedTranscript(request.transcript)

      // oMLX: translate the framework's reasoning level into the chat
      // template's thinking controls.
      let reasoning = Self.reasoning(for: request.contextOptions.reasoningLevel)

      // oMLX: with `.afterReasoning`, the schema is asked for in words and
      // the answer's JSON is read from the reply, unless reasoning is off.
      let readsJSONFromAnswer =
        request.schema != nil
        && configuration.structuredOutput == .afterReasoning
        && reasoning.enableThinking != false

      // oMLX: the grammar enforces the schema's shape, but the model only
      // learns what each field means from the prompt. Honor
      // `includeSchemaInPrompt` (on unless the caller turns it off). Without
      // a grammar, the prompt is all the model has, so it's always included.
      if let schema = request.schema,
        readsJSONFromAnswer || request.contextOptions.includeSchemaInPrompt != false
      {
        try Self.appendSchemaInstruction(for: schema, to: &messages)
      }

      // oMLX: map every sampling mode onto oMLX's native parameters instead
      // of rejecting top-k and seeds.
      let sampling = try Self.sampling(
        for: request.generationOptions.samplingMode,
        temperature: request.generationOptions.temperature
      )
      let seed = try sampling.seed ?? Self.seed(in: request.metadata)

      // Translate the framework's request into the OpenAI-compatible wire format.
      let chatRequest = ChatCompletionsClient.ChatCompletionRequest(
        model: configuration.modelName,
        messages: messages,
        temperature: sampling.temperature,
        topP: sampling.topP,
        topK: sampling.topK,
        seed: seed,
        maxCompletionTokens: request.generationOptions.maximumResponseTokens,
        tools: request.enabledToolDefinitions.map { tool in
          ChatCompletionsClient.Tool(
            function: ChatCompletionsClient.Tool.Function(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters
            )
          )
        },
        toolChoice: ChatCompletionsClient.ChatCompletionRequest.ToolChoice(
          mode: {
            switch request.generationOptions.toolCallingMode?.kind {
            case .allowed, .none: .auto
            case .required: .required
            case .disallowed: .none
            @unknown default: .auto
            }
          }()
        ),
        // oMLX: `structured_outputs` fails loudly when a schema can't be
        // compiled to a grammar; `response_format` would quietly fall back to
        // unenforced JSON.
        structuredOutputs: readsJSONFromAnswer
          ? nil
          : request.schema.map { schema in
            ChatCompletionsClient.StructuredOutputs(json: schema)
          },
        reasoningEffort: reasoning.effort,
        enableThinking: reasoning.enableThinking
      )

      // Stream the response back into the framework via `channel`.
      try await Self.processChunks(
        client.streamChatCompletions(request: chatRequest),
        into: channel,
        readsJSONFromAnswer: readsJSONFromAnswer
      )
    }

    // oMLX: warm the server ahead of the first request. This loads the model
    // if oMLX unloaded it, and fills oMLX's prefix cache with the
    // instructions and tool definitions so the first response starts sooner.
    public func prewarm(model: OMLXLanguageModel, transcript: Transcript) {
      guard var messages = try? convertedTranscript(transcript), !messages.isEmpty else {
        return
      }
      // Chat templates expect a user turn; its text sits after the shared prefix.
      if messages.last?.role != .user {
        messages.append(
          ChatCompletionsClient.ChatMessage(
            role: .user,
            content: [ChatCompletionsClient.MessageContent(text: "Hello")]
          )
        )
      }
      let tools = transcript.flatMap { entry -> [ChatCompletionsClient.Tool] in
        guard case .instructions(let instructions) = entry else { return [] }
        return instructions.toolDefinitions.map { tool in
          ChatCompletionsClient.Tool(
            function: ChatCompletionsClient.Tool.Function(
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters
            )
          )
        }
      }
      let warmup = ChatCompletionsClient.ChatCompletionRequest(
        model: configuration.modelName,
        messages: messages,
        maxCompletionTokens: 1,
        tools: tools.isEmpty ? nil : tools
      )
      let client = makeClient()
      Task {
        // Best effort: a failed warm-up surfaces on the first real request.
        do {
          for try await _ in client.streamChatCompletions(request: warmup) {}
        } catch {}
      }
    }

    private static func processChunks<ChunkSequence: AsyncSequence>(
      _ chunks: ChunkSequence,
      into channel: LanguageModelExecutorGenerationChannel,
      readsJSONFromAnswer: Bool = false
    ) async throws where ChunkSequence.Element == ChatCompletionsClient.ChatCompletionChunk {
      // Per-index `id`/`name` for tool calls. The first delta for a given
      // index supplies them; later deltas at the same index typically carry
      // only argument fragments and are routed using these latched values.
      // Argument accumulation is the framework's job — we just forward each
      // delta via `.appendArguments`.
      var toolCallRouting: [Int: (id: String, name: String)] = [:]

      // Stable entryIDs per event type for the duration of this stream.
      // Without these, interleaved reasoning/response/toolCalls chunks would
      // split into multiple transcript entries — the framework only coalesces
      // consecutive events of the same type into the trailing entry.
      let responseEntryID = UUID().uuidString
      let reasoningEntryID = UUID().uuidString
      let toolCallsEntryID = UUID().uuidString

      // oMLX: Qwen-style chat templates put blank lines after the thinking
      // block. Drop leading whitespace so each entry starts with visible text.
      var hasReasoningText = false
      var hasResponseText = false

      // oMLX: with `StructuredOutput.afterReasoning`, the answer is held back
      // until it's complete, so its JSON can be read from it, and so is the
      // usage that follows it.
      var answer = ""
      var answerTokenCount = 0
      var calledTools = false
      var finishReason: String?
      var heldUsage: (usage: ChatCompletionsClient.ChatCompletionChunk.Usage, model: String)?

      for try await chunk in chunks {
        // oMLX: stop promptly when the caller cancels.
        try Task.checkCancellation()

        if let reason = chunk.choices.first?.finishReason { finishReason = reason }
        if let delta = chunk.choices.first?.delta {
          // oMLX: skip the empty deltas oMLX sends as keep-alives.
          if var reasoning = delta.reasoningContent {
            if !hasReasoningText {
              reasoning = String(reasoning.drop(while: \.isWhitespace))
            }
            if !reasoning.isEmpty {
              hasReasoningText = true
              await channel.send(
                .reasoning(
                  entryID: reasoningEntryID,
                  action: .appendText(reasoning, tokenCount: 1)
                )
              )
            }
          }

          if let toolCallDeltas = delta.toolCalls {
            for toolCallDelta in toolCallDeltas {
              let existing = toolCallRouting[toolCallDelta.index] ?? (id: "", name: "")
              let routing = (
                id: existing.id + (toolCallDelta.id ?? ""),
                name: existing.name + (toolCallDelta.function?.name ?? "")
              )
              toolCallRouting[toolCallDelta.index] = routing

              guard !routing.id.isEmpty, !routing.name.isEmpty else { continue }
              calledTools = true

              await channel.send(
                .toolCalls(
                  entryID: toolCallsEntryID,
                  action: .toolCall(
                    id: routing.id,
                    name: routing.name,
                    action: .appendArguments(
                      toolCallDelta.function?.arguments ?? "",
                      tokenCount: 1
                    )
                  )
                )
              )
            }
          } else if var text = delta.content {
            if !hasResponseText {
              text = String(text.drop(while: \.isWhitespace))
            }
            if !text.isEmpty, readsJSONFromAnswer {
              hasResponseText = true
              answer += text
              answerTokenCount += 1
            } else if !text.isEmpty {
              hasResponseText = true
              await channel.send(
                .response(
                  entryID: responseEntryID,
                  action: .appendText(text, tokenCount: 1)
                )
              )
            }
          }
        }

        // Send usage AFTER content so the authoritative cumulative total
        // overwrites any tokens credited by `appendText` for this chunk.
        if let usage = chunk.usage {
          if readsJSONFromAnswer {
            heldUsage = (usage, chunk.model)
          } else {
            await sendUsage(usage, model: chunk.model, entryID: responseEntryID, into: channel)
          }
        }
      }

      // oMLX: read the JSON from the finished answer, then report usage.
      guard readsJSONFromAnswer else { return }
      if !answer.isEmpty || !calledTools {
        guard let json = Self.lastJSONValue(in: answer) else {
          throw finishReason == "length"
            ? OMLXLanguageModel.RequestError.answerCutShort(answer)
            : OMLXLanguageModel.RequestError.answerWithoutJSON(answer)
        }
        await channel.send(
          .response(entryID: responseEntryID, action: .appendText(json, tokenCount: answerTokenCount))
        )
      }
      if let heldUsage {
        await sendUsage(heldUsage.usage, model: heldUsage.model, entryID: responseEntryID, into: channel)
      }
    }


    // oMLX: usage, and the server's own timing, for the response entry.
    private static func sendUsage(
      _ usage: ChatCompletionsClient.ChatCompletionChunk.Usage,
      model: String,
      entryID responseEntryID: String,
      into channel: LanguageModelExecutorGenerationChannel
    ) async {
      await channel.send(
        .response(
          entryID: responseEntryID,
          action: .updateUsage(
            input: .init(
              totalTokenCount: usage.promptTokens,
              cachedTokenCount: usage.promptTokensDetails?.cachedTokens ?? 0
            ),
            output: .init(
              totalTokenCount: usage.completionTokens,
              reasoningTokenCount: usage.completionTokensDetails?.reasoningTokens ?? 0
            )
          )
        )
      )

      // oMLX: attach the server's own timing to the response entry.
      var metadata: [String: any ConvertibleToGeneratedContent] = [
        MetadataKey.model: model
      ]
      if let value = usage.timeToFirstToken {
        metadata[MetadataKey.timeToFirstToken] = value
      }
      if let value = usage.promptTokensPerSecond {
        metadata[MetadataKey.promptTokensPerSecond] = value
      }
      if let value = usage.generationTokensPerSecond {
        metadata[MetadataKey.generationTokensPerSecond] = value
      }
      await channel.send(
        .response(entryID: responseEntryID, action: .updateMetadata(metadata))
      )
    }

    // oMLX: the answer's JSON is the last complete object or array in it,
    // which skips any prose or code fence around it. A whole answer that's a
    // JSON value of another kind, such as `true`, counts too.
    static func lastJSONValue(in answer: String) -> String? {
      func parses(_ text: Substring) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
      }

      var spans: [Range<String.Index>] = []
      var depth = 0
      var start: String.Index?
      var inString = false
      var escaped = false
      var index = answer.startIndex
      while index < answer.endIndex {
        let character = answer[index]
        if inString {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            inString = false
          }
        } else if character == "\"" {
          inString = depth > 0
        } else if character == "{" || character == "[" {
          if depth == 0 { start = index }
          depth += 1
        } else if (character == "}" || character == "]"), depth > 0 {
          depth -= 1
          if depth == 0, let start {
            spans.append(start..<answer.index(after: index))
          }
        }
        index = answer.index(after: index)
      }
      for span in spans.reversed() where parses(answer[span]) {
        return String(answer[span])
      }

      // A stray bracket in the prose can leave the spans unbalanced. Then
      // take the longest object or array that ends at the answer's last
      // closing bracket.
      if let end = answer.lastIndex(where: { $0 == "}" || $0 == "]" }) {
        let starts = answer[...end].indices.filter { answer[$0] == "{" || answer[$0] == "[" }
        for start in starts where parses(answer[start...end]) {
          return String(answer[start...end])
        }
      }

      let whole = answer.trimmingCharacters(in: .whitespacesAndNewlines)
      return !whole.isEmpty && parses(Substring(whole)) ? whole : nil
    }

    // oMLX: replaces upstream's `topP(_:)`, which rejected top-k and seeds
    // and sent `top_p: 0` for greedy (oMLX reads that as "no nucleus filter").
    private static func sampling(
      for mode: GenerationOptions.SamplingMode?,
      temperature: Double?
    ) throws -> (temperature: Double?, topP: Double?, topK: Int?, seed: UInt64?) {
      guard let mode else { return (temperature, nil, nil, nil) }
      switch mode.kind {
      case .greedy:
        return (0, nil, nil, nil)
      case .randomTopK(let k, let seed):
        return (temperature, nil, k, seed)
      case .randomProbabilityThreshold(let threshold, let seed):
        return (temperature, threshold, nil, seed)
      @unknown default:
        throw OMLXLanguageModel.RequestError.invalidRequest(
          "Unknown sampling mode \(mode.kind) is not supported"
        )
      }
    }

    // oMLX: the seed a request's metadata carries, if any.
    private static func seed(in metadata: [String: GeneratedContent]) throws -> UInt64? {
      guard let content = metadata[OMLXLanguageModel.RequestKey.seed] else { return nil }
      guard let seed = try? content.value(Int.self), seed >= 0 else {
        throw OMLXLanguageModel.RequestError.invalidRequest(
          "\(OMLXLanguageModel.RequestKey.seed) should be a whole number, 0 or more."
        )
      }
      return UInt64(seed)
    }

    // oMLX: reasoning levels become `reasoning_effort` (each chat template
    // validates its own vocabulary, and oMLX falls back gracefully), and
    // `.custom("none")` turns thinking off entirely.
    private static func reasoning(
      for level: ContextOptions.ReasoningLevel?
    ) -> (effort: String?, enableThinking: Bool?) {
      guard let level else { return (nil, nil) }
      switch level {
      case .light:
        return ("low", true)
      case .moderate:
        return ("medium", true)
      case .deep:
        return ("high", true)
      case .custom(let value):
        switch value.lowercased() {
        case "none", "off":
          return (nil, false)
        default:
          return (value, true)
        }
      @unknown default:
        return (nil, nil)
      }
    }

    // oMLX: describe the schema in the latest user message. Appending there
    // keeps the cached prefix (instructions, tools, history) intact.
    private static func appendSchemaInstruction(
      for schema: GenerationSchema,
      to messages: inout [ChatCompletionsClient.ChatMessage]
    ) throws {
      guard let index = messages.lastIndex(where: { $0.role == .user }) else { return }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let json = String(decoding: try encoder.encode(schema), as: UTF8.self)
      messages[index].content.append(
        ChatCompletionsClient.MessageContent(
          text: "Respond with JSON that conforms to this JSON Schema:\n\(json)"
        )
      )
    }

    private func convertedTranscript(
      _ entries: some Collection<Transcript.Entry>
    ) throws -> [ChatCompletionsClient.ChatMessage] {

      // Converts a single transcript segment into chat-completion message content.
      func convertedSegment(
        _ segment: Transcript.Segment,
        in entry: Transcript.Entry
      ) throws -> [ChatCompletionsClient.MessageContent] {
        switch segment {
        case .text(let text):
          return [
            ChatCompletionsClient.MessageContent(
              text: text.content
            )
          ]
        // Structured content is serialized to JSON text on the wire.
        case .structure(let structure):
          return [
            ChatCompletionsClient.MessageContent(
              text: structure.content.jsonString
            )
          ]
        case .attachment(let attachment):
          switch attachment.content {
          case .image(let image):
            #if canImport(CoreImage)
            // Images are inlined as base64 data URLs (JPEG).
            let base64String = image.cgImage.jpegData().base64EncodedString()
            let dataURL = URL(string: "data:image/jpeg;base64,\(base64String)")!
            let imageURL = ChatCompletionsClient.MessageContent.ImageURL(url: dataURL)
            return [ChatCompletionsClient.MessageContent(imageURL: imageURL)]
            #else
            guard let url = image.url else {
              throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                  unsupportedContent: [entry],
                  debugDescription: "Image attachment without a URL is not supported by \(Self.self) on this platform."
                )
              )
            }
            let dataURL: URL
            if url.scheme == "data" {
              dataURL = url
            } else {
              let data = try Data(contentsOf: url)
              let base64String = data.base64EncodedString()
              dataURL = URL(string: "data:image/jpeg;base64,\(base64String)")!
            }
            let imageURL = ChatCompletionsClient.MessageContent.ImageURL(url: dataURL)
            return [ChatCompletionsClient.MessageContent(imageURL: imageURL)]
            #endif
          // oMLX: name the custom data attachments added in iOS 27.2. This
          // model doesn't opt in to any, so the framework rejects them first.
          case .data:
            throw LanguageModelError.unsupportedTranscriptContent(
              LanguageModelError.UnsupportedTranscriptContent(
                unsupportedContent: [entry],
                debugDescription: "Data attachments are not supported by \(Self.self)."
              )
            )
          @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(
              LanguageModelError.UnsupportedTranscriptContent(
                unsupportedContent: [entry],
                debugDescription: "Attachment type not supported by \(Self.self)."
              )
            )
          }
        @unknown default:
          throw LanguageModelError.unsupportedTranscriptContent(
            LanguageModelError.UnsupportedTranscriptContent(
              unsupportedContent: [entry],
              debugDescription: "Unknown segment type not supported by \(Self.self)"
            )
          )
        }
      }

      var messages: [ChatCompletionsClient.ChatMessage] = []
      // Reasoning entries are buffered and attached to the next assistant
      // message (response or toolCalls) via `reasoning_content`. If a turn
      // has only reasoning with no following assistant entry, it's emitted
      // as a standalone assistant message.
      var pendingReasoning: String? = nil

      func consumePendingReasoning() -> String? {
        defer { pendingReasoning = nil }
        return pendingReasoning
      }

      // Translate each transcript entry into one chat-completion message.
      for entry in entries {
        switch entry {
        case .instructions(let instructions):
          // Instructions become system-role messages.
          messages.append(
            ChatCompletionsClient.ChatMessage(
              role: .system,
              content: try instructions.segments.flatMap { try convertedSegment($0, in: entry) }
            )
          )

        case .prompt(let prompt):
          // User prompts; flush any orphaned reasoning as a message first.
          if let reasoning = consumePendingReasoning() {
            messages.append(
              ChatCompletionsClient.ChatMessage(
                role: .assistant,
                reasoningContent: reasoning
              )
            )
          }
          messages.append(
            ChatCompletionsClient.ChatMessage(
              role: .user,
              content: try prompt.segments.flatMap { try convertedSegment($0, in: entry) }
            )
          )

        case .toolCalls(let toolCalls):
          // Tool calls ride along on an assistant message, with any buffered reasoning attached.
          messages.append(
            ChatCompletionsClient.ChatMessage(
              role: .assistant,
              toolCalls: toolCalls.map { call in
                ChatCompletionsClient.ToolCall(
                  id: call.id,
                  function: ChatCompletionsClient.ToolCall.FunctionCall(
                    name: call.toolName,
                    arguments: call.arguments.jsonString
                  )
                )
              },
              reasoningContent: consumePendingReasoning()
            )
          )

        case .toolOutput(let toolOutput):
          // Tool outputs become tool-role messages keyed by the originating call ID.
          messages.append(
            ChatCompletionsClient.ChatMessage(
              role: .tool,
              content: try toolOutput.segments.flatMap { try convertedSegment($0, in: entry) },
              toolCallID: toolOutput.id
            )
          )

        case .response(let response):
          // Assistant responses; attach any buffered reasoning to this message.
          messages.append(
            ChatCompletionsClient.ChatMessage(
              role: .assistant,
              content: try response.segments.flatMap { try convertedSegment($0, in: entry) },
              reasoningContent: consumePendingReasoning()
            )
          )

        case .reasoning(let reasoning):
          // Buffer reasoning text; it will attach to the next assistant entry.
          let text = reasoning.segments.compactMap { segment -> String? in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
          }.joined()
          pendingReasoning = (pendingReasoning ?? "") + text

        // oMLX: custom data entries (iOS 27.2) have no chat-completions form,
        // and this model never emits them.
        case .data:
          continue

        @unknown default:
          continue
        }
      }

      // Trailing reasoning with no following assistant entry — emit it solo.
      if let reasoning = consumePendingReasoning() {
        messages.append(
          ChatCompletionsClient.ChatMessage(
            role: .assistant,
            reasoningContent: reasoning
          )
        )
      }

      return messages
    }
  }
}

private struct ChatCompletionsClient {
  let baseURL: URL
  let headers: [String: String]
  let session: URLSession

  func streamChatCompletions(
    request: ChatCompletionRequest
  ) -> AsyncThrowingStream<ChatCompletionChunk, Swift.Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try buildURLRequest(for: request)
          #if canImport(Darwin)
          let (stream, response) = try await session.bytes(for: urlRequest)
          let httpResponse = response as! HTTPURLResponse

          guard httpResponse.statusCode == 200 else {
            // oMLX: map the error envelope to a typed error.
            throw OMLXLanguageModel.mappedError(
              statusCode: httpResponse.statusCode,
              body: try await stream.reduce(Data(), { $0 + [$1] }),
              retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
            )
          }

          for try await line in stream.lines {
            if let chunk = try parseStreamLine(line) {
              continuation.yield(chunk)
            }
          }

          continuation.finish()
          #else
          let (data, response) = try await session.data(for: urlRequest)
          let httpResponse = response as! HTTPURLResponse

          guard httpResponse.statusCode == 200 else {
            // oMLX: map the error envelope to a typed error.
            throw OMLXLanguageModel.mappedError(
              statusCode: httpResponse.statusCode,
              body: data,
              retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
            )
          }

          let body = String(data: data, encoding: .utf8) ?? ""
          for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let chunk = try parseStreamLine(String(line)) {
              continuation.yield(chunk)
            }
          }

          continuation.finish()
          #endif

        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func buildURLRequest(for request: ChatCompletionRequest) throws -> URLRequest {
    let isVersioned = baseURL.pathComponents.contains { component in
      component.wholeMatch(of: #/v\d+/#) != nil
    }
    let endpoint = isVersioned ? "/chat/completions" : "/v1/chat/completions"
    let url = baseURL.appendingPathComponent(endpoint)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    for (header, value) in headers {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }

    let encoder = JSONEncoder()
    urlRequest.httpBody = try encoder.encode(request)

    return urlRequest
  }

  func parseStreamLine(_ line: String) throws -> ChatCompletionChunk? {
    let trimmedLine = line.trimmingCharacters(in: .whitespaces)

    // Skip empty lines and comments
    guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix(":") else {
      return nil
    }

    if trimmedLine.hasPrefix("data: ") {
      let jsonString = String(trimmedLine.dropFirst(6))  // Remove "data: "

      if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
        return nil
      }

      guard let jsonData = jsonString.data(using: .utf8) else {
        throw OMLXLanguageModel.RequestError.invalidStreamData
      }

      let decoder = JSONDecoder()
      do {
        return try decoder.decode(ChatCompletionChunk.self, from: jsonData)
      } catch {
        if (try? decoder.decode(OMLXLanguageModel.ErrorResponse.self, from: jsonData)) != nil {
          // oMLX: map mid-stream errors the same way as HTTP errors.
          throw OMLXLanguageModel.mappedError(statusCode: nil, body: jsonData)
        }
        throw error
      }
    }

    return nil
  }

  struct ChatCompletionRequest: Encodable {
    enum ToolChoiceMode: String, Encodable {
      case auto
      case required
      case none
    }

    struct ToolChoice: Encodable {
      let mode: ToolChoiceMode

      func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(mode)
      }
    }

    var model: String
    var messages: [ChatMessage]
    var temperature: Double? = nil
    var topP: Double? = nil
    var topK: Int? = nil  // oMLX
    var seed: UInt64? = nil  // oMLX
    var maxCompletionTokens: Int? = nil
    var tools: [Tool]? = nil
    var toolChoice: ChatCompletionRequest.ToolChoice? = nil
    var structuredOutputs: StructuredOutputs? = nil  // oMLX: replaces `responseFormat`
    var reasoningEffort: String? = nil  // oMLX
    var enableThinking: Bool? = nil  // oMLX
    var stream = true
    var streamOptions = StreamOptions(includeUsage: true)

    struct StreamOptions: Encodable {
      var includeUsage: Bool

      private enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
      }
    }

    private enum CodingKeys: String, CodingKey {
      case model
      case messages
      case temperature
      case topP = "top_p"
      case topK = "top_k"
      case seed
      case maxCompletionTokens = "max_completion_tokens"
      case tools
      case structuredOutputs = "structured_outputs"
      case reasoningEffort = "reasoning_effort"
      case enableThinking = "enable_thinking"
      case stream
      case streamOptions = "stream_options"
      case toolChoice = "tool_choice"
    }
  }

  struct ChatMessage: Encodable {
    var role: Role
    var content: [MessageContent]
    var toolCalls: [ToolCall]?
    var toolCallID: String?
    var reasoningContent: String?

    private enum CodingKeys: String, CodingKey {
      case role
      case content
      case toolCalls = "tool_calls"
      case toolCallID = "tool_call_id"
      case reasoningContent = "reasoning_content"
    }

    enum Role: String, Encodable {
      case system
      case user
      case assistant
      case tool
    }

    init(
      role: Role,
      content: [MessageContent] = [],
      toolCalls: [ToolCall]? = nil,
      toolCallID: String? = nil,
      reasoningContent: String? = nil
    ) {
      self.role = role
      self.content = content
      self.toolCalls = toolCalls
      self.toolCallID = toolCallID
      self.reasoningContent = reasoningContent
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(role, forKey: .role)

      let hasToolCalls = toolCalls?.isEmpty == false
      let compactText = content.count == 1 ? content.first?.text : nil

      if let compactText {
        try container.encode(compactText, forKey: .content)
      } else if !hasToolCalls && !content.isEmpty {
        try container.encode(content, forKey: .content)
      }

      try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
      try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
      try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }
  }

  struct Tool: Encodable {
    var type: String = "function"
    var function: Function

    struct Function: Encodable {
      let name: String
      let description: String
      let parameters: GenerationSchema
    }
  }

  struct ToolCall: Codable {
    var id: String
    var type = "function"
    var function: FunctionCall

    struct FunctionCall: Codable {
      var name: String
      var arguments: String
    }
  }

  // oMLX: vLLM-style structured output, compiled to a grammar by oMLX.
  // Replaces upstream's `ResponseFormat`.
  struct StructuredOutputs: Encodable {
    var json: GenerationSchema
  }

  struct ChatCompletionChunk: Decodable {
    let id: String
    let model: String
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
      let delta: Delta
      // oMLX: `"length"` when the model ran out of response tokens.
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
      }

      struct Delta: Decodable {
        var role: String?
        var content: String?
        var reasoningContent: String?
        var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
          case role
          case content
          case reasoningContent = "reasoning_content"
          case toolCalls = "tool_calls"
        }
      }
    }

    struct ToolCallDelta: Decodable {
      let index: Int
      let id: String?
      let type: String?
      let function: FunctionCallDelta?

      struct FunctionCallDelta: Decodable {
        let name: String?
        let arguments: String?
      }
    }

    fileprivate struct Usage: Decodable {
      let promptTokens: Int
      let completionTokens: Int
      let promptTokensDetails: PromptTokensDetails?
      let completionTokensDetails: CompletionTokensDetails?
      // oMLX: timing extensions on the final usage chunk.
      let timeToFirstToken: Double?
      let promptTokensPerSecond: Double?
      let generationTokensPerSecond: Double?

      fileprivate struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
          case cachedTokens = "cached_tokens"
        }
      }

      fileprivate struct CompletionTokensDetails: Decodable {
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
          case reasoningTokens = "reasoning_tokens"
        }
      }

      private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case timeToFirstToken = "time_to_first_token"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
      }
    }
  }

  struct MessageContent: Codable {
    var type: ContentType
    var text: String?
    var imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
    }

    enum ContentType: String, Codable {
      case text
      case imageURL = "image_url"
    }

    struct ImageURL: Codable {
      var url: URL
      var detail: String? = "auto"
    }

    init(text: String) {
      self.type = .text
      self.text = text
      self.imageURL = nil
    }

    init(imageURL: ImageURL) {
      self.type = .imageURL
      self.text = nil
      self.imageURL = imageURL
    }
  }
}

#if canImport(CoreImage)
private extension CGImage {
  func jpegData() -> Data {
    let imageData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      /* data */ imageData,
      /* format */ UTType.jpeg.identifier as CFString,
      /* count */ 1,
      /* options */ nil
    )!
    CGImageDestinationAddImage(destination, self, nil)
    CGImageDestinationFinalize(destination)
    return Data(referencing: imageData)
  }
}
#endif
