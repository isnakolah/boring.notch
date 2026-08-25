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
/// The prompts as they are actually sent, fetched from the engine.
///
/// This file used to hold a *copy* of the default wording so the pane had
/// something to show. It drifted: by the time it was replaced it was previewing
/// a JSON contract with different keys from the one the host had been using for
/// months, and offering "start from the default" would have handed the user
/// wording that was never sent. The prompts live in files under the runtime
/// directory now, and this reads them across the sandbox line.
@MainActor
final class CopilotPromptDefaults: ObservableObject {
    static let shared = CopilotPromptDefaults()

    @Published private(set) var prompts: [String: String] = [:]
    private var loaded = false

    /// Idempotent: the pane calls this on appear and the engine exports the
    /// defaults on first ask, so there is nothing to arrange beforehand.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        CallaEngineClient.shared.fetchPrompts { [weak self] prompts in
            self?.prompts = prompts
        }
    }

    /// Force a re-read, for after an edit outside the app.
    func reload() {
        loaded = false
        loadIfNeeded()
    }

    var base: String { prompts["live/base.md"] ?? "" }

    func persona(_ persona: String) -> String {
        prompts["live/personas/\(persona).md"] ?? ""
    }

    static let baseHint = "Replaces the base guidance in full. Keep the JSON contract — `headline`, `angles`, `confirm`."

    /// Shown in an empty editor. The real block is long, so the placeholder is
    /// its opening rather than the whole thing.
    func personaHint(for persona: String) -> String {
        let block = self.persona(persona)
        guard !block.isEmpty else {
            return "What should the copilot do differently on this kind of call?"
        }
        let firstLine = block.split(separator: "\n").first.map(String.init) ?? block
        return firstLine.count > 160 ? String(firstLine.prefix(157)) + "…" : firstLine
    }
}
