import Defaults
import SwiftUI

/// What the copilot is actually told.
///
/// These used to live only on the gateway, which meant the one thing that
/// decides whether a suggestion is useful — who you are and what kind of call
/// this is — could not be changed from the machine having the call. They ride
/// `call_start` now; anything left empty falls back to the gateway's own text,
/// so an untouched install behaves exactly as it did.
///
/// The text is a prompt payload and nothing else. It is carried to the capture
/// host on stdin and never becomes a command-line argument, which is what keeps
/// the engine's allowlist stance intact for everything that names a process.
struct CopilotPromptsPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @Default(.callaCopilotAboutMe) private var aboutMe
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotPersonaOverrides) private var overrides
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaCopilotBaseGuidance) private var baseGuidance

    @State private var editingPersona: String = Defaults[.callaCopilotPersona]
    @State private var showAdvanced = false
    @State private var newPersonaID = ""
    @State private var newPersonaError: String?

    var body: some View {
        SettingsPane(eyebrow: "Call copilot", title: "Prompts",
                     detail: "What the copilot knows about you, and how it is told to answer. Blank fields use the gateway's own wording.") {
            aboutCard
            personaCard
            advancedCard
            previewCard
        }
    }

    // MARK: - About me

    private var aboutCard: some View {
        SettingCard("About you",
                    detail: "Role, company, what you build, anything the copilot should assume rather than infer from the call. Injected into every call, whatever the persona.") {
            VStack(alignment: .leading, spacing: 6) {
                PromptEditor(text: $aboutMe,
                             placeholder: "Senior engineer at Acme. I own the billing service. We migrated off Stripe last quarter.",
                             minHeight: 96)
                CharacterCount(count: aboutMe.count, limit: PromptLimits.about)
            }
        }
    }

    // MARK: - Personas

    private var personaCard: some View {
        SettingCard("Personas",
                    detail: "One short block per kind of call, layered on top of the base guidance. Editing one changes every future call that uses it.") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $editingPersona) {
                    ForEach(CallaCopilotPersona.all(including: Array(customPersonas.keys)), id: \.self) { value in
                        Text(CallaCopilotPersona.title(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    PromptEditor(text: personaBinding,
                                 placeholder: CopilotPromptDefaults.personaHint(for: editingPersona),
                                 minHeight: 120)
                    HStack {
                        CharacterCount(count: (overrides[editingPersona] ?? customPersonas[editingPersona] ?? "").count,
                                       limit: PromptLimits.persona)
                        Spacer(minLength: 8)
                        if isCustom(editingPersona) {
                            Button("Delete persona", role: .destructive) { deleteCustomPersona() }
                                .controlSize(.small)
                        } else if overrides[editingPersona] != nil {
                            Button("Reset to default") { overrides[editingPersona] = nil }
                                .controlSize(.small)
                        } else {
                            Text("Using the gateway's own wording.")
                                .font(NotchType.rowDetail)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Divider()

                SettingRow("Add a persona",
                           detail: "Lowercase letters, numbers and hyphens — the id travels to the gateway.") {
                    HStack(spacing: 6) {
                        TextField("board-review", text: $newPersonaID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Button("Add") { addCustomPersona() }
                            .controlSize(.small)
                            .disabled(newPersonaID.isEmpty)
                    }
                }
                if let newPersonaError {
                    Text(newPersonaError)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.attention)
                }
            }
        }
    }

    // MARK: - Base guidance

    private var advancedCard: some View {
        SettingCard("Base guidance",
                    detail: "The block every persona sits on. It defines the JSON the copilot must reply with — a bad edit here makes every suggestion unreadable, and the notch simply goes quiet.",
                    tint: baseGuidance.isEmpty ? nil : NotchTint.attention) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow("Override the base guidance",
                           detail: baseGuidance.isEmpty
                               ? "Off. The gateway's own wording is used, which is what almost everyone should do."
                               : "On. You are responsible for keeping the JSON contract intact.") {
                    Toggle("", isOn: Binding(
                        get: { showAdvanced || !baseGuidance.isEmpty },
                        set: { enabled in
                            showAdvanced = enabled
                            if !enabled { baseGuidance = "" }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if showAdvanced || !baseGuidance.isEmpty {
                    PromptEditor(text: $baseGuidance,
                                 placeholder: CopilotPromptDefaults.baseHint,
                                 minHeight: 200,
                                 monospaced: true)
                    HStack {
                        CharacterCount(count: baseGuidance.count, limit: PromptLimits.base)
                        Spacer(minLength: 8)
                        Button("Start from the default") {
                            baseGuidance = CopilotPromptDefaults.base
                        }
                        .controlSize(.small)
                        Button("Reset") { baseGuidance = "" }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Preview

    /// What is actually sent, assembled in the same order the gateway does it.
    ///
    /// Worth the space: three fields that each silently fall back to a default
    /// are otherwise impossible to reason about without starting a call.
    private var previewCard: some View {
        SettingCard("What gets sent",
                    detail: "Composed for \(CallaCopilotPersona.title(persona)) — the persona a call starts with today.") {
            ScrollView {
                Text(composedPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(NotchSurface.sunken,
                        in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        }
    }

    private var composedPrompt: String {
        var blocks: [String] = []
        blocks.append(baseGuidance.isEmpty ? "[gateway base guidance]" : baseGuidance)
        let guidance = overrides[persona] ?? customPersonas[persona] ?? ""
        blocks.append(guidance.isEmpty ? "[gateway persona block: \(persona)]" : guidance)
        let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty {
            blocks.append("About the person you are helping:\n\(about)")
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Editing

    /// One binding over two stores: built-in personas write an override,
    /// user-made ones write the persona itself. Keeping them apart is what lets
    /// "Reset to default" mean something for the four the gateway seeds.
    private var personaBinding: Binding<String> {
        Binding(
            get: { overrides[editingPersona] ?? customPersonas[editingPersona] ?? "" },
            set: { value in
                if isCustom(editingPersona) {
                    customPersonas[editingPersona] = value
                } else if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    overrides[editingPersona] = nil
                } else {
                    overrides[editingPersona] = value
                }
            })
    }

    private func isCustom(_ id: String) -> Bool {
        !CallaCopilotPersona.builtIn.contains(id)
    }

    private func addCustomPersona() {
        let id = newPersonaID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard CallaCopilotPersona.isValidCustomID(id) else {
            newPersonaError = "Use 1–24 lowercase letters, numbers or hyphens, and not one of the four built in."
            return
        }
        guard customPersonas[id] == nil else {
            newPersonaError = "That persona already exists."
            return
        }
        customPersonas[id] = ""
        editingPersona = id
        newPersonaID = ""
        newPersonaError = nil
    }

    private func deleteCustomPersona() {
        let id = editingPersona
        customPersonas[id] = nil
        if persona == id { persona = "generic" }
        editingPersona = "generic"
    }
}

// MARK: - Pieces

/// Caps the engine enforces too. Stated here so the UI can say no before a call
/// is refused for a reason the user cannot see.
enum PromptLimits {
    static let about = 1200
    static let persona = 2000
    static let base = 8000
}

private struct PromptEditor: View {
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

private struct CharacterCount: View {
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
