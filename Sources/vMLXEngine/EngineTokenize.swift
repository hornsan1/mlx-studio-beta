// SPDX-License-Identifier: Apache-2.0
//
// EngineTokenize.swift — public tokenizer entry points on the Engine actor.
//
// Closes the shared blocker behind iter-108 §186 (`/v1/messages/count_tokens`
// returned a labeled 501) and, partially, iter-111 §189 (Ollama legacy
// `context: [int]`): routes needed a way to reach the loaded model's
// tokenizer + chat-template pipeline without breaking the container's actor
// isolation. These methods run the SAME preparation path as
// `Stream.performOneGenerationPass` (buildChatMessages → buildTemplateExtras
// → processor.prepare), so the counts they return match the `prompt_tokens`
// a subsequent generation reports.
//
// Known divergence (documented, acceptable): MCP-merged tools are injected
// during `stream()` after its own MCP resolution pass and are NOT counted
// here — a count_tokens caller supplies tools explicitly per the Anthropic
// contract. The Gemma thinking+tools auto-disable guard IS mirrored.

import Foundation
import vMLXLMCommon

extension Engine {

    /// Count the prompt tokens `request` would prefill, by running the
    /// exact template + processor path `stream()` uses (chat template,
    /// thinking stubs, tool specs, image expansion) without generating.
    ///
    /// Throws `EngineError.notImplemented` when no model is loaded —
    /// routes map that to a labeled 501/409 as appropriate.
    public func countChatTokens(request: ChatRequest) async throws -> Int {
        guard let container = self.loaded else {
            throw EngineError.notImplemented(
                "count_tokens — no model loaded; load a model first")
        }

        let resolvedSessionId = request.sessionId.flatMap { UUID(uuidString: $0) }
        let resolvedChatId = request.chatId.flatMap { UUID(uuidString: $0) }
        let resolved = await self.settings.resolved(
            sessionId: resolvedSessionId,
            chatId: resolvedChatId,
            request: RequestOverride.from(request))

        // Mirror Stream.swift's effectiveThinking resolution (incl. §385
        // `max` effort level) so the thinking stub / template branches
        // match what generation will actually render.
        let effortImpliesThinking: Bool? = request.reasoningEffort.flatMap {
            let v = $0.lowercased()
            if v == "none" || v.isEmpty { return false }
            if v == "low" || v == "medium" || v == "high" || v == "max" { return true }
            return nil
        }
        var effectiveThinking: Bool = request.enableThinking
            ?? resolved.enableThinking
            ?? effortImpliesThinking
            ?? false

        let caps = self.modelCapabilities

        // tool_choice: "none" — tools never reach the template (iter-49).
        var effectiveTools = request.tools
        if let tc = request.toolChoice, case .none = tc {
            effectiveTools = nil
        }

        // Gemma 4 thinking+tools collision guard (Round 16 / mlxstudio#71)
        // — same auto-disable as the stream path so counts agree.
        if effectiveThinking,
           let tools = effectiveTools, !tools.isEmpty,
           let fam = caps?.family.lowercased(),
           fam.hasPrefix("gemma")
        {
            effectiveThinking = false
        }

        let chatMessages = await Engine.buildChatMessages(
            from: request,
            effectiveThinking: effectiveThinking,
            modelStampsThink: caps?.thinkInTemplate ?? false,
            responseFormatInstruction: Engine.responseFormatInstruction(
                from: request.responseFormat))

        let templateExtras = Engine.buildTemplateExtras(
            request: request, resolved: resolved,
            effectiveThinking: effectiveThinking)

        let toolSpecs: [ToolSpec]? = effectiveTools.map { buildToolSpecs(from: $0) }

        return try await container.perform { ctx in
            let userInput = UserInput(
                chat: chatMessages, tools: toolSpecs,
                additionalContext: templateExtras)
            let prepared = try await ctx.processor.prepare(input: userInput)
            return prepared.text.tokens.size
        }
    }

    /// Encode raw text through the loaded model's tokenizer (no chat
    /// template). Backs `/tokenize`-style routes.
    public func tokenizeText(_ text: String) async throws -> [Int] {
        guard let container = self.loaded else {
            throw EngineError.notImplemented(
                "tokenize — no model loaded; load a model first")
        }
        return try await container.perform { ctx in
            ctx.tokenizer.encode(text: text)
        }
    }

    /// Decode token IDs back to text through the loaded model's tokenizer.
    /// Backs `/detokenize`-style routes and future Ollama `context: [int]`
    /// support (iter-111 §189).
    public func detokenize(_ tokens: [Int]) async throws -> String {
        guard let container = self.loaded else {
            throw EngineError.notImplemented(
                "detokenize — no model loaded; load a model first")
        }
        return try await container.perform { ctx in
            ctx.tokenizer.decode(tokenIds: tokens)
        }
    }
}
