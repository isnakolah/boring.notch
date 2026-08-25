import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// One meeting's page: what it has, and how to give it more.
///
/// The whole editing surface lives here rather than in the list, which is what
/// lets the list stay scannable. Same three ways in as the notch — drag, choose,
/// type — because someone who learned it there should not have to learn it again.
struct CopilotKnowledgeDetailPane: View {
    let route: KnowledgeRoute

    @StateObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var attach = CallaKnowledgeAttach.shared
    @Default(.callaCopilotPersona) private var persona

    @State private var scope: String = "series"
    @State private var isTargeted = false
    @State private var draft = ""
    @State private var draftTitle = ""
    @State private var viewing: CallaKnowledgeNote?
    @State private var problem: String?

    private var event: EventModel? {
        guard case let .event(id) = route else { return nil }
        return library.events.first { $0.id == id }
    }

    private var notes: [CallaKnowledgeNote] {
        switch route {
        case .event:
            guard let event else { return [] }
            return library.notes(for: event).sorted { $0.updatedAt > $1.updatedAt }
        case .everyCall:
            return library.notes(scope: "always").sorted { $0.updatedAt > $1.updatedAt }
        case .byPersona:
            return library.notes(scope: "persona").sorted { $0.updatedAt > $1.updatedAt }
        case .orphaned:
            return library.orphanedNotes.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Where anything added on this page goes.
    private var target: KnowledgeTarget {
        switch route {
        case .event:
            guard let event else { return .everyCall }
            let choices = KnowledgeTarget.choices(for: event)
            return choices.first { $0.scope == scope } ?? choices.first ?? .everyCall
        case .byPersona:
            return KnowledgeTarget(
                kind: .persona(id: persona),
                title: "Every \(CallaCopilotPersona.title(persona)) call",
                detail: "Only that persona")
        default:
            return .everyCall
        }
    }

    private var canAdd: Bool {
        switch route {
        // By-persona is addable now that it files under the persona scope it
        // claims. It is the answer to "the copilot should know my CV on every
        // interview but not on a support call".
        case .event, .everyCall, .byPersona: true
        case .orphaned: false
        }
    }

    var body: some View {
        SettingsPane(SettingsPage.copilotKnowledgeDetail(route), titleOverride: title) {
            if let problem { problemCard(problem) }
            if case .event = route, event == nil {
                SettingCard {
                    Text("This meeting is no longer on your calendar. Anything attached to it is under “Not on your calendar any more”.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            if canAdd { addCard }
            contentsCard
            if let viewing { viewerCard(viewing) }
        }
        .task {
            if library.events.isEmpty { await library.load() }
            if let event, event.seriesID == nil || !event.hasRecurrenceRules { scope = "event" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaKnowledgeDidChange)) { _ in
            Task { await library.load() }
        }
    }

    // MARK: - Titles

    private var eyebrow: String {
        switch route {
        case .event: "Meeting"
        case .everyCall, .byPersona: "Call copilot"
        case .orphaned: "Needs attention"
        }
    }

    private var title: String {
        switch route {
        case .event: event?.title ?? "This meeting"
        case .everyCall: "Every call"
        case .byPersona: "By kind of call"
        case .orphaned: "Not on your calendar any more"
        }
    }

    private var detail: String? {
        switch route {
        case .event:
            guard let event else { return nil }
            let when = event.start.formatted(date: .abbreviated, time: .shortened)
            let calls = library.callCount(for: event)
            var parts = [when]
            if event.hasRecurrenceRules { parts.append("repeats") }
            if calls > 0 { parts.append("\(calls) call\(calls == 1 ? "" : "s") recorded") }
            return parts.joined(separator: " · ")
        case .everyCall:
            return "Read at the start of every call, whatever the meeting is about."
        case .byPersona:
            return "Applies when the copilot is set to that persona. Add these from the Prompts pane."
        case .orphaned:
            return "Still stored, and still applied if the meeting reappears."
        }
    }

    // MARK: - Adding

    private var addCard: some View {
        SettingCard("Add something") {
            VStack(alignment: .leading, spacing: 12) {
                if case .event = route, let event, event.hasRecurrenceRules, event.seriesID != nil {
                    Picker("", selection: $scope) {
                        Text("Every repeat").tag("series")
                        Text("Just this one").tag("event")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                HStack(alignment: .top, spacing: 12) {
                    dropZone
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("Title", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                        PromptEditor(
                            text: $draft,
                            placeholder: "They churned on latency last quarter. Dana signs the renewal.",
                            minHeight: 74)
                        HStack {
                            Spacer(minLength: 0)
                            Button("Add note") { commitDraft() }
                                .controlSize(.small)
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if let status = attach.status {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(NotchTint.healthy)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 7) {
            Image(systemName: attach.isWorking ? "hourglass" : "doc.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(attach.isWorking ? "Reading…" : "Drop a file")
                .font(.system(size: 11.5, weight: .semibold))
            Text("PDF, Word, Pages export, plain text or a scan")
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose…") { attach.attachChosenFiles(to: target) }
                .controlSize(.small)
                .disabled(attach.isWorking)
        }
        .padding(.horizontal, 12)
        .frame(width: 210)
        .frame(minHeight: 148)
        .background(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                guard await attach.accept(providers) else {
                    problem = "That is not a kind of file the copilot can read."
                    return
                }
                problem = nil
                await attach.commitPending(to: target)
                await library.load()
            }
            return true
        }
    }

    private func commitDraft() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let heading = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""; draftTitle = ""
        Task {
            await attach.attach(text: body, title: heading.isEmpty ? target.title : heading, to: target)
            await library.load()
        }
    }

    // MARK: - Contents

    private var contentsCard: some View {
        SettingCard(
            "What it has",
            detail: notes.isEmpty ? nil : "Files are searched when a question needs them. Notes are in front of the copilot the whole call."
        ) {
            if notes.isEmpty {
                Text(canAdd
                     ? "Nothing yet."
                     : "Nothing here.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        noteRow(note)
                        if index < notes.count - 1 { Divider().padding(.leading, 32) }
                    }
                }
            }
        }
    }

    private func noteRow(_ note: CallaKnowledgeNote) -> some View {
        HStack(spacing: 10) {
            Image(systemName: note.symbol)
                .font(.system(size: 14))
                .foregroundStyle(note.isDocument ? Color.accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(NotchType.rowTitle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(note.subtitle)
                    Text("·")
                    Text(note.scopeLabel)
                    if note.isAlwaysInView {
                        Text("·")
                        Text("always in view").foregroundStyle(NotchTint.healthy)
                    }
                }
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(note.isEditable ? "Edit" : "View") { viewing = note }
                .controlSize(.small)
            Button {
                CallaEngineClient.shared.deleteKnowledge(id: note.id) { _ in
                    Task { await library.load() }
                    CallaKnowledgeFocus.shared.refresh()
                }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove")
        }
        .padding(.vertical, 7)
    }

    // MARK: - Viewer

    private func viewerCard(_ note: CallaKnowledgeNote) -> some View {
        SettingCard(
            note.title.isEmpty ? "Note" : note.title,
            detail: note.isEditable
                ? nil
                : "What the copilot reads. Rebuilt from its source, so edits here would not stick.",
            tint: NotchTint.active
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if note.isEditable {
                    TextField("Title", text: bind(note, \.title))
                        .textFieldStyle(.roundedBorder)
                }
                PromptEditor(
                    text: bind(note, \.body),
                    placeholder: "",
                    minHeight: note.isEditable ? 150 : 240,
                    monospaced: !note.isEditable)
                    .disabled(!note.isEditable)
                HStack {
                    Text(note.subtitle).font(NotchType.rowDetail).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Button("Close") { viewing = nil }
                        .controlSize(.small)
                    if note.isEditable {
                        Button("Save") {
                            guard let edited = viewing else { return }
                            CallaEngineClient.shared.saveKnowledge(edited) { _ in
                                viewing = nil
                                Task { await library.load() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func bind<T>(
        _ note: CallaKnowledgeNote,
        _ path: WritableKeyPath<CallaKnowledgeNote, T>
    ) -> Binding<T> {
        Binding(
            get: { viewing?[keyPath: path] ?? note[keyPath: path] },
            set: { viewing?[keyPath: path] = $0 })
    }

    private func problemCard(_ text: String) -> some View {
        SettingCard(tint: NotchTint.attention) {
            HStack(spacing: 10) {
                SettingStatusIcon(ok: false)
                Text(text).font(NotchType.rowDetail).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { problem = nil }.controlSize(.small)
            }
        }
    }
}
