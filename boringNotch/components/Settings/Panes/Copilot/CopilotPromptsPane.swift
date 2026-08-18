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
        SettingsPane(SettingsPage.copilotPrompts) {
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
