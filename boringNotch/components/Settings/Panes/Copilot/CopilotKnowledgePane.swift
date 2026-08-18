import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Everything the copilot can be given something for, browsable like the rest of
/// System Settings.
///
/// A list of *meetings* rather than a list of notes, and it includes meetings with
/// nothing attached — those are the ones you came here to fix, and a list that
/// only showed prepared meetings would hide exactly the rows worth opening.
/// Picking one pushes its own page, so the surface stays a browser and the
/// editing happens somewhere with room for it.
struct CopilotKnowledgePane: View {
    @StateObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var focus = CallaKnowledgeFocus.shared

    @Environment(\.settingsRouter) private var router
    @State private var search = ""
    @State private var loaded = false

    var body: some View {
        root
            .task {
                guard !loaded else { return }
                loaded = true
                await library.load()
                // Arriving from the calendar's right-click: open that meeting
                // rather than making someone find it again in a month of events.
                if let eventID = focus.eventID {
                    router?.push(.copilotKnowledgeDetail(.event(id: eventID)))
                    focus.clearFocus()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .callaKnowledgeDidChange)) { _ in
                Task { await library.load() }
            }
    }

    private var root: some View {
        SettingsPane(SettingsPage.copilotKnowledge) {
            overview
            everywhereCard
            meetingsCard
            if !library.orphanedNotes.isEmpty { orphanCard }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        SettingCard {
            HStack(alignment: .top, spacing: 22) {
                figure("\(library.notes.filter(\.isDocument).count)", "file\(library.notes.filter(\.isDocument).count == 1 ? "" : "s")")
                figure("\(library.notes.filter { !$0.isDocument }.count)", "note\(library.notes.filter { !$0.isDocument }.count == 1 ? "" : "s")")
                figure("\(library.preparedEvents.count)", "meeting\(library.preparedEvents.count == 1 ? "" : "s") prepared")
                Spacer(minLength: 8)
                TextField("Search meetings and files", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(label).font(NotchType.rowDetail).foregroundStyle(.secondary)
        }
    }

    // MARK: - Not tied to a meeting

    private var everywhereCard: some View {
        SettingCard("Everywhere", detail: "Background that is not tied to one meeting.") {
            VStack(spacing: 0) {
                navigationRow(
                    route: .everyCall,
                    symbol: "globe",
                    title: "Every call",
                    detail: "In front of the copilot whatever the meeting",
                    count: library.notes(scope: "always").count)
                Divider().padding(.leading, 32)
                navigationRow(
                    route: .byPersona,
                    symbol: "theatermasks",
                    title: "By kind of call",
                    detail: "Only when the copilot is set to that persona",
                    count: library.notes(scope: "persona").count)
            }
        }
    }

    // MARK: - Meetings

    private var meetingsCard: some View {
        SettingCard(
            "Meetings",
            detail: library.events.isEmpty
                ? "No meetings in the last week or the next month."
                : "The last week and the next month. A repeating meeting shares whatever is attached to the series."
        ) {
            if library.isLoading && library.events.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your calendar…").font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
            } else {
                let groups = library.groupedByDay(matching: search)
                if groups.isEmpty {
                    Text(search.isEmpty
                         ? "Nothing to show."
                         : "No meeting matches “\(search)”.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(groups, id: \.day) { group in
                            VStack(spacing: 0) {
                                HStack {
                                    Text(dayLabel(group.day))
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(0.7)
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.bottom, 5)

                                ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                                    eventRow(event)
                                    if index < group.events.count - 1 {
                                        Divider().padding(.leading, 32)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EventModel) -> some View {
        let attached = library.notes(for: event)
        let calls = library.callCount(for: event)
        return navigationRow(
            route: .event(id: event.id),
            symbol: event.seriesID != nil && event.hasRecurrenceRules ? "repeat" : "calendar",
            title: event.title,
            detail: [
                event.start.formatted(date: .omitted, time: .shortened),
                calls > 0 ? "\(calls) call\(calls == 1 ? "" : "s")" : nil,
                event.videoCallURL != nil ? "has a call link" : nil,
            ].compactMap { $0 }.joined(separator: " · "),
            count: attached.count,
            documents: attached.filter(\.isDocument).count)
    }

    /// One tappable row that pushes a page. Deliberately the same shape for a
    /// meeting and for the two catch-alls, so the list reads as one thing.
    private func navigationRow(
        route: KnowledgeRoute,
        symbol: String,
        title: String,
        detail: String,
        count: Int,
        documents: Int = 0
    ) -> some View {
        Button {
            router?.push(.copilotKnowledgeDetail(route))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(NotchType.rowTitle).lineLimit(1)
                    Text(detail).font(NotchType.rowDetail).foregroundStyle(.tertiary).lineLimit(1)
                }

                Spacer(minLength: 8)

                if count > 0 {
                    HStack(spacing: 4) {
                        if documents > 0 {
                            Image(systemName: "paperclip").font(.system(size: 9, weight: .bold))
                        }
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Orphans

    private var orphanCard: some View {
        SettingCard(
            "Not on your calendar any more",
            detail: "These are attached to a meeting that has been deleted, or whose occurrences have all passed. They still apply if it comes back.",
            tint: NotchTint.attention
        ) {
            navigationRow(
                route: .orphaned,
                symbol: "questionmark.folder",
                title: "Unmatched",
                detail: "Review or remove",
                count: library.orphanedNotes.count,
                documents: library.orphanedNotes.filter(\.isDocument).count)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInTomorrow(day) { return "TOMORROW" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: day).uppercased()
    }
}
