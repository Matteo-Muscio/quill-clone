import Foundation

/// Text-only, single-turn serialization with thinking explicitly disabled and
/// no tools. This matches the publishers' templates for that supported branch;
/// it does not attempt to interpret arbitrary chat/tool histories.
enum NotesPromptFormat {
    // Publisher templates checked 2026-09-07:
    // https://huggingface.co/Qwen/Qwen3.5-2B/blob/15852e8c16360a2fea060d615a32b45270f8a8fc/chat_template.jinja
    // https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/chat_template.jinja
    // https://huggingface.co/HuggingFaceTB/SmolLM3-3B/blob/a07cc9a04f16550a088caea529712d1d335b0ac1/chat_template.jinja
    static func wrap(system: String, user: String, model: NotesModel, date: Date = Date()) -> String {
        switch model {
        case .qwen35_2B, .qwen35_4B:
            let system = escaped(system.trimmingCharacters(in: .whitespacesAndNewlines))
            let user = escaped(user.trimmingCharacters(in: .whitespacesAndNewlines))
            return "<|im_start|>system\n\(system)<|im_end|>\n"
                + "<|im_start|>user\n\(user)<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .smolLM3_3B:
            // This API always chooses /no_think; callers cannot switch reasoning
            // or bypass the metadata header through a system-template directive.
            let stripped = system.replacingOccurrences(of: "/no_think", with: "")
                .replacingOccurrences(of: "/think", with: "")
                .replacingOccurrences(of: "/system_override", with: "")
            let custom = String(stripped.reversed().drop(while: \.isWhitespace).reversed())
            let instructions = custom.isEmpty
                ? "You are a helpful AI assistant named SmolLM, trained by Hugging Face."
                : escaped(custom)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "dd MMMM yyyy"
            // The published no-tools branch has no system <|im_end|> between
            // custom instructions and the user header. Retain that exact format,
            // including Smol's single newline after the empty thinking prefix.
            return "<|im_start|>system\n## Metadata\n\n"
                + "Knowledge Cutoff Date: June 2025\n"
                + "Today Date: \(formatter.string(from: date))\n"
                + "Reasoning Mode: /no_think\n\n"
                + "## Custom Instructions\n\n\(instructions)\n\n"
                + "<|im_start|>user\n\(escaped(user))<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n"
        }
    }

    /// Publisher temperature/filter settings with neutral local penalties.
    /// Qwen 2B text recommendations differ from the 4B card's general non-thinking
    /// recommendations; neither is inferred from the other's vision settings.
    static func samplingArguments(for model: NotesModel, options: NotesCompletionOptions = .init()) -> [String] {
        var temperature: String
        var topP: String
        var topK: String
        switch model {
        case .qwen35_2B:
            // https://huggingface.co/Qwen/Qwen3.5-2B/blob/15852e8c16360a2fea060d615a32b45270f8a8fc/README.md
            temperature = "1.0"; topP = "1.0"; topK = "20"
        case .qwen35_4B:
            // https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/README.md
            temperature = "0.7"; topP = "0.8"; topK = "20"
        case .smolLM3_3B:
            // https://huggingface.co/HuggingFaceTB/SmolLM3-3B/blob/a07cc9a04f16550a088caea529712d1d335b0ac1/generation_config.json
            // The publisher supplies temp/top_p; its Transformers 4.54 config
            // inherits top_k=50, no min_p, and repetition_penalty=1.0:
            // https://github.com/huggingface/transformers/blob/v4.54.0/src/transformers/generation/configuration_utils.py
            temperature = "0.6"; topP = "0.95"; topK = "50"
        }
        if let value = options.temperature { temperature = String(value) }
        if let value = options.topP { topP = String(value) }
        if let value = options.topK { topK = String(value) }
        // Explicit order follows Transformers' temperature -> top_k -> top_p
        // filtering, with penalties first; omit unrelated optional samplers.
        // Qwen recommends presence 2.0 (2B) / 1.5 (4B), but b10837 completion
        // feeds prompt tokens into its 64-token penalty history as well as output:
        // https://github.com/ggml-org/llama.cpp/blob/b10837/tools/completion/completion.cpp#L687-L695
        // https://github.com/ggml-org/llama.cpp/blob/b10837/common/sampling.cpp#L467-L498
        // https://github.com/ggml-org/llama.cpp/blob/b10837/src/llama-sampler.cpp#L2919-L2976
        // vLLM presence instead uses generated tokens only, across output history:
        // https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/utils.py#L73-L88
        // The pinned CLI has no output-only option. Keep presence neutral so
        // copying source evidence is not penalized; this intentionally differs
        // from publisher presence settings, with quality checked separately.
        // The explicit 64-token window is inert while all penalties are neutral.
        return ["--samplers", "penalties;temperature;top_k;top_p;min_p",
                "--temp", temperature, "--top-p", topP, "--top-k", topK,
                "--min-p", "0.0", "--presence-penalty", "0.0",
                "--repeat-penalty", "1.0", "--frequency-penalty", "0.0", "--repeat-last-n", "64"]
    }

    /// Only our trusted, already-escaped assistant suffix may open reasoning.
    /// The raw completion CLI does not wire --reasoning-budget to this prompt.
    static func thinkingPrompt(from prompt: String, model: NotesModel) throws -> String {
        let suffix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        guard model == .qwen35_4B, prompt.hasSuffix(suffix) else {
            throw MeetingNotesError.invalidGenerationOptions
        }
        return String(prompt.dropLast(suffix.count)) + "<|im_start|>assistant\n<think>\n"
    }

    /// Discard the stop marker and anything after it, then neutralize generated
    /// control tokens before replay. A capped first pass may end mid-sentence;
    /// the explicit trusted closing tag still sends pass two into final mode.
    static func finalPrompt(thinkingPrompt: String, reasoning: Data) -> String {
        let raw = String(decoding: reasoning, as: UTF8.self)
        let body = raw.components(separatedBy: "</think>").first ?? ""
        return thinkingPrompt + escaped(body) + "\n</think>\n\n"
    }

    /// Preserve readable source text while preventing literal model-control
    /// token spellings from creating extra roles or reasoning boundaries.
    private static func escaped(_ value: String) -> String {
        // These non-ChatML controls also appear in the pinned publishers'
        // tokenizer_config.json added-token vocabularies. Ordinary comparisons
        // and HTML are source evidence and must keep their exact spelling.
        let pattern = #"<\|[^<>\r\n]*\|>|</?(?:think|tool_call|tool_response)>|<tts_(?:pad|text_bos|text_eod|text_bos_single)>"#
        let expression = try! NSRegularExpression(pattern: pattern)
        var result = value
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        // Replacing backwards preserves the original UTF-16 match offsets.
        for match in expression.matches(in: value, range: fullRange).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range]).replacingOccurrences(of: "<", with: "< ")
                .replacingOccurrences(of: ">", with: " >")
            result.replaceSubrange(range, with: token)
        }
        return result
    }
}
