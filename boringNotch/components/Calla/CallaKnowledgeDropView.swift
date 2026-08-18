import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// One surface for giving the copilot something to read.
///
/// Two ways in and they meet here, which is the point — a drop onto the notch and
/// a right-click on a calendar event should not teach two different interfaces.
/// The only difference is which question is still open:
///
///  * dropped a file, no meeting chosen → ask which meeting;
///  * came from the calendar, meeting known → ask for the file.
///
/// Both are laid out the same way: the thing you brought on the left, the thing
/// you are choosing on the right. A notch is much wider than it is tall, so a
/// stack of full-width rows runs off the bottom while half the panel sits empty —
/// two columns is the shape the space actually is.
struct CallaKnowledgeDropView: View {
    @ObservedObject private var attach = CallaKnowledgeAttach.shared
    @EnvironmentObject var coordinator: BoringViewCoordinator

    @State private var isTargeted = false
    @State private var paneTargeted = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let target = attach.presetTarget {
                attachColumns(target)
                typeRow(target)
            } else {
                pickerColumns
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // In picker mode the only drop target was the one that appears once a
        // meeting is already chosen, so arriving here mid-drag — which is what
        // holding over Remember now does — left the file with nowhere to land.
        // The whole pane takes it, and the meeting is chosen afterwards.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(paneTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
                .padding(4)
        )
        .onDrop(of: [.fileURL], isTargeted: $paneTargeted) { providers in
            guard attach.presetTarget == nil else { return false }
            Task {
                guard await attach.accept(providers) else {
                    attach.failure = "That is not a kind of file the copilot can read."
                    return
                }
            }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "paperclip")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if attach.presetTarget != nil, attach.targets.count > 1 {
                scopeStrip
            }

            Button("Done") {
                attach.cancelPending()
                coordinator.currentView = .home
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private var title: String {
        if let target = attach.presetTarget { return target.title }
        return fileSummary
    }

    private var subtitle: String {
        if let failure = attach.failure { return failure }
        if let status = attach.status { return status }
        if let target = attach.presetTarget { return target.detail }
        return "Which meeting is this for?"
    }

    private var statusTint: Color {
        if attach.failure != nil { return NotchTint.attention }
        if attach.status != nil { return NotchTint.healthy }
        return Color.white.opacity(0.55)
    }

    private var fileSummary: String {
        let names = attach.pending.map(\.name)
        switch names.count {
        case 0: return "Nothing to add"
        case 1: return names[0]
        default: return "\(names[0]) and \(names.count - 1) more"
        }
    }

    /// "Every repeat" versus "just this one", when the meeting recurs. Lives in
    /// the header because it qualifies the title rather than the drop zone.
    private var scopeStrip: some View {
        HStack(spacing: 3) {
            ForEach(attach.targets) { choice in
                Button { attach.retarget(choice) } label: {
                    Text(label(for: choice))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(choice.id == attach.presetTarget?.id
                                ? Color.accentColor.opacity(0.32)
                                : Color.white.opacity(0.07)))
                        .foregroundStyle(choice.id == attach.presetTarget?.id
                            ? Color.white
                            : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(for target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "Every call"
        case .series: "Every repeat"
        case .event: "Just this one"
        }
    }

    // MARK: - Mode A — files in hand, choose a meeting

    /// Left: what was dropped. Right: where it can go.
    private var pickerColumns: some View {
        HStack(alignment: .top, spacing: 10) {
            column(header: "DROPPED") {
                ScrollView(.vertical) {
                    VStack(spacing: 3) {
                        ForEach(attach.pending) { file in
                            HStack(spacing: 7) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                                Text(file.name)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.05)))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(width: 200)

            column(header: "ADD TO") {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(attach.targets) { target in
                            Button {
                                Task { await attach.commitPending(to: target) }
                            } label: {
                                targetRow(target)
                            }
                            .buttonStyle(.plain)
                        }
                        if attach.targets.count <= 1 {
                            hint("No meetings in the next day and a half. It can still go to every call, or to any meeting from Settings.")
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .disabled(attach.isWorking)
        .overlay { if attach.isWorking { working } }
    }

    private func targetRow(_ target: KnowledgeTarget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: target))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint(for: target))
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 0) {
                Text(target.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(target.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let startsAt = target.startsAt {
                Text(startsAt, style: .time)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    // MARK: - Mode B — meeting known, add files

    /// Left: drop. Right: pick from disk, and what is already there.
    private func attachColumns(_ target: KnowledgeTarget) -> some View {
        HStack(alignment: .top, spacing: 10) {
            column(header: "DRAG IN") {
                dropZone(target)
            }
            .frame(width: 210)

            column(header: attach.attached.isEmpty ? "OR CHOOSE" : "ALREADY ADDED") {
                VStack(spacing: 5) {
                    Button { attach.attachChosenFiles(to: target) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Choose a file…")
                                .font(.system(size: 10.5, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(attach.isWorking)

                    if attach.attached.isEmpty {
                        hint("Nothing attached to this meeting yet.")
                        Spacer(minLength: 0)
                    } else {
                        attachedList
                    }
                }
            }
        }
    }

    private func dropZone(_ target: KnowledgeTarget) -> some View {
        VStack(spacing: 5) {
            Image(systemName: attach.isWorking ? "hourglass" : "doc.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.5))
            Text(attach.isWorking ? "Reading…" : "Drop a PDF, deck or document")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(attach.isWorking
                 ? "Scanned pages take a moment longer."
                 : "Searched during the call, when a question needs it.")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.white.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                guard await attach.accept(providers) else {
                    attach.failure = "That is not a kind of file the copilot can read."
                    return
                }
                await attach.commitPending(to: target)
            }
            return true
        }
    }

    private var attachedList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 3) {
                ForEach(attach.attached) { note in
                    HStack(spacing: 7) {
                        Image(systemName: note.symbol)
                            .font(.system(size: 9.5))
                            .foregroundStyle(note.isDocument
                                ? Color.accentColor : Color.white.opacity(0.5))
                            .frame(width: 13)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(note.subtitle)
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { attach.remove(note) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.04)))
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Typing

    /// Full width under both columns: a sentence is a different gesture from a
    /// file, and giving it the whole footer keeps it from reading as part of
    /// either column.
    private func typeRow(_ target: KnowledgeTarget) -> some View {
        HStack(spacing: 7) {
            TextField("Or type something it should know", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06)))
                .onSubmit { commitDraft(target) }

            Button { commitDraft(target) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.white.opacity(0.25) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commitDraft(_ target: KnowledgeTarget) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { await attach.attach(text: body, title: target.title, to: target) }
    }

    // MARK: - Pieces

    /// A titled column. The label is what makes two panels read as a choice
    /// rather than as two unrelated boxes.
    private func column<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.system(size: 8, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.35))
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(Color.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reading is not instant for a scanned PDF — Vision runs page by page — so
    /// the wait is named rather than left as a spinner over a frozen list.
    private var working: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Reading \(fileSummary)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.6)))
    }

    private func symbol(for target: KnowledgeTarget) -> String {
        switch target.kind {
        case .always: "globe"
        case .series: "repeat"
        case .event: "calendar"
        }
    }

    private func tint(for target: KnowledgeTarget) -> Color {
        switch target.kind {
        case .always: Color.white.opacity(0.5)
        case .series: Color.accentColor
        case .event: Color.accentColor.opacity(0.75)
        }
    }
}
