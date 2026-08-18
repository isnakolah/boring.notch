//
//  PromptEditor.swift
//  boringNotch
//
//  The prompt editing pieces, shared by Prompts and Knowledge. They lived in
//  CopilotPromptsPane.swift, so a file named for one pane owned another's types.
//

import SwiftUI

enum PromptLimits {
    static let about = 1200
    static let persona = 2000
    static let base = 8000
    /// One knowledge note. The engine caps the *composed* block at the same
    /// figure, so a single note at the ceiling leaves no room for any other — the
    /// pane says the number, and the engine drops what will not fit rather than
    /// refusing the call.
    static let knowledge = 8000
}

struct PromptEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 100
    var monospaced = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
        }
        .frame(minHeight: minHeight)
        .background(NotchSurface.sunken,
                    in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(NotchSurface.hairline, lineWidth: 1))
    }

    private var font: Font {
        monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12)
    }
}

struct CharacterCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count) / \(limit)")
            .font(NotchType.figure)
            .foregroundStyle(count > limit ? AnyShapeStyle(NotchTint.attention) : AnyShapeStyle(.tertiary))
            .help(count > limit ? "Over the limit — the engine will refuse this." : "")
    }
}

/// Copies of the gateway's own text, for the "start from the default" button
/// and the placeholders.
///
/// Deliberately a copy rather than something fetched: it is a starting point
/// for an edit, and the live default stays whatever the gateway ships. If the
/// two drift, the gateway is right.
enum CopilotPromptDefaults {
    static let base = """
    You are a live call copilot.

    You receive a running transcript of a phone or video call, one turn at a time.
    Turns are labelled by source:
    - "them" — the other party
    - "me" — the person you are helping

    Your job is to help "me" answer well, in the moment. You are read during a live
    call, so brevity is not a style preference — it is the whole constraint.

    When you respond, return a single JSON object and nothing else:

    {
      "headline": "the thing they were actually asked, in under 12 words",
      "angles": ["a way to answer", "a different way to answer"],
      "confirm": ["a fact worth checking before asserting it"]
    }

    Rules:
    - "headline" is required. If there is no open question, return {"headline": ""}
      and nothing else — silence is a valid and frequently correct output.
    - "angles": zero to three, each a distinct approach, under 25 words.
    - "confirm": zero to three. Only facts, numbers, names, commitments or dates
      that appeared in the call and should be verified before being stated.
    - Never invent specifics.
    - Transcription is imperfect. Work from context rather than quoting a garble.
    - Do not narrate, greet, apologise, or wrap the JSON in prose or code fences.
    """

    static let baseHint = "Replaces the gateway's base guidance in full. Keep the JSON contract."

    static func personaHint(for persona: String) -> String {
        switch persona {
        case "interview":
            return "Favour concrete, structured answers grounded in specific past work…"
        case "sales":
            return "Track what they have said they need, separately from what they merely mentioned…"
        case "support":
            return "Acknowledge the specific problem before proposing a fix…"
        case "generic":
            return "Favour clarity and directness."
        default:
            return "What should the copilot do differently on this kind of call?"
        }
    }
}
