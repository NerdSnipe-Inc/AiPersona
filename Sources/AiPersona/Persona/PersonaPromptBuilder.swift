import Foundation

/// Builds the persona-identity and memory-context fragments of a chat system prompt. Deliberately
/// does NOT build a complete system prompt — a host app's own domain-specific instructions
/// (tool-calling guidance, safety rules, etc.) are its own concern, not this package's; the host
/// composes `identityPreamble(...) + "\n\n" + <its own instructions> + memorySection(...)`.
public enum PersonaPromptBuilder {
    /// Includes an explicit "you have persistent memory" instruction unconditionally — not only
    /// when `memorySection(_:)` has content. A small on-device model given no instruction that a
    /// memory system exists will fall back to its trained "I'm just an AI, I don't retain things"
    /// disclaimer the instant a user says "remember X", even on the very first turn before any
    /// fact has been extracted yet. Verified against real on-device behavior: omitting this
    /// caused exactly that disclaiming response regardless of what was in the memory block.
    /// `now` defaults to the real current time; callers pass a fixed value only in tests. Stamping
    /// the date/time directly into the prompt — rather than exposing it as a tool call — costs
    /// nothing: the model always needs it, so a tool round-trip would only burn a turn (and tokens
    /// out of the 4,096-token on-device window) to answer a question that's cheap to just tell it.
    public static func identityPreamble(name: String, personality: String, now: Date = Date()) -> String {
        "Your name is \(name). \(personality) You have persistent memory across conversations — "
            + "when the user asks you to remember something, acknowledge it naturally and "
            + "confidently (for example, \"Got it, I'll remember that.\") rather than saying you "
            + "lack memory or can't retain information. Facts you've learned in past "
            + "conversations are automatically surfaced to you below, in a dedicated section, "
            + "whenever they're relevant — never claim you don't have memory just because nothing "
            + "relevant happens to be surfaced on this particular turn. The current date and time "
            + "is \(Self.dateTimeFormatter.string(from: now))."
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    /// Returns `""` for `nil`/empty context so a host app can unconditionally append this to its
    /// prompt without a branch — an empty string is a no-op when concatenated. Frames the facts
    /// as established knowledge the model should trust, not raw data to question — a bare list
    /// with no framing gives the model no reason to treat them as "memories" of its own.
    public static func memorySection(_ memoryContext: String?) -> String {
        guard let memoryContext, !memoryContext.isEmpty else { return "" }
        return "\n\n### RELEVANT MEMORY ###\nThings you already know about this user from past "
            + "conversations — treat these as established facts, not something to verify or "
            + "question:\n\(memoryContext)"
    }

    /// Distinct from `memorySection` on purpose: a retrieved reference/product-knowledge fact is
    /// not something learned about *this user*, and labeling it as "memory" would risk the model
    /// treating an objective product rule as a personal fact about the person it's talking to.
    /// Wording matches what was validated end-to-end (60/60, mean 9.89/10 on a 60-case
    /// non-sealed development gate) before this was wired into any host app — see
    /// packs/ghl-core-v1/reviews/e4b-first-principles-pipeline-audit-2026-08-10.md, addendum
    /// 2026-08-18/19.
    public static func knowledgeSection(_ knowledgeContext: String?) -> String {
        guard let knowledgeContext, !knowledgeContext.isEmpty else { return "" }
        return "\n\n### RELEVANT KNOWLEDGE ###\nThe following are reviewed, authoritative rules "
            + "relevant to this request. Use them as ground truth; do not contradict them, and do "
            + "not claim knowledge beyond what is stated here plus ordinary common sense:\n\(knowledgeContext)"
    }
}
