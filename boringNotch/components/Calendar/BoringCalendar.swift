//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

enum WheelPickerStyle {
    case dots   // compact day-dot indicators
    case plate  // full-width date cards (weekday + numeral + month) that page horizontally
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config
    var style: WheelPickerStyle = .dots

    // Plate cards are full-width and self-center, so they need no edge spacers.
    private var spacerNum: Int { style == .dots ? config.offset : 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a dot cell
                        Spacer()
                            .frame(width: 16, height: 16)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        switch style {
                        case .dots:
                            dotButton(date: date, isSelected: isSelected, id: index) {
                                selectedDate = date
                                byClick = true
                                withAnimation {
                                    scrollPosition = index
                                }
                                if Defaults[.enableHaptics] {
                                    haptics.toggle()
                                }
                            }
                        case .plate:
                            plateCard(date: date, id: index)
                        }
                    }
                }
            }
            .frame(height: style == .dots ? 16 : nil)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .safeAreaPadding(style == .dots ? .horizontal : [])
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    // A single day rendered as a tappable dot. The selected day widens into an
    // accent pill; today (when not selected) reads slightly brighter than the rest.
    private func dotButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let dotColor: Color = isSelected
            ? Color.effectiveAccent
            : Color.white.opacity(isToday ? 0.5 : 0.18)
        return Button(action: onClick) {
            Capsule(style: .continuous)
                .fill(dotColor)
                .frame(width: isSelected ? 16 : 7, height: 7)
                .shadow(color: isSelected ? Color.effectiveAccent.opacity(0.6) : .clear, radius: 4, y: 2)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).day()))
        .id(id)
    }

    // Full-width date card used by `.plate` style: weekday, big numeral, month/year.
    @ViewBuilder
    private func plateCard(date: Date, id: Int) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(isToday ? Color.effectiveAccent : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(date.date)")
                .font(.system(size: 44, weight: .bold))
                .monospacedDigit()
                .tracking(-1)
                .foregroundColor(.white)
            Text(date.formatted(.dateTime.month(.abbreviated).year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerRelativeFrame(.horizontal)
        .id(id)
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @State private var selectedDate = Date()

    // "Today hero" date plate: the big date (weekday + numeral + month/year) is a
    // horizontally scrollable pager — scroll/swipe it to move between days — with a
    // row of day-dots below that mirrors the selection and is also tappable.
    private var datePlate: some View {
        VStack(alignment: .leading, spacing: 9) {
            WheelPicker(selectedDate: $selectedDate, config: Config(), style: .plate)
                .frame(height: 82)

            WheelPicker(selectedDate: $selectedDate, config: Config(), style: .dots)
        }
    }

    var body: some View {
        let filteredEvents = EventListView.filteredEvents(events: calendarManager.events)
        HStack(alignment: .center, spacing: 14) {
            datePlate
                .frame(width: 84, alignment: .leading)

            Group {
                if filteredEvents.isEmpty {
                    EmptyEventsView(selectedDate: selectedDate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EventListView(events: calendarManager.events)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .listRowBackground(Color.clear)
        .frame(maxHeight: .infinity)
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.pomodoroCalendarIcon) private var pomodoroCalendarIcon
    @Default(.callaTutorEnabled) private var callaTutorEnabled
    @Default(.callaCalendarEnabled) private var callaCalendarEnabled
    @Default(.callaCopilotEnabled) private var callaCopilotEnabled
    @ObservedObject private var callaEngine = CallaEngineClient.shared


    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            // Filter out all-day events if setting is enabled
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredEvents) { event in
                        // A tap gesture rather than a Button wrapper: the row now
                        // holds its own timer Button, and nested buttons do not
                        // hit-test reliably on macOS.
                        eventRow(event)
                            .contentShape(Rectangle())
                            .onTapGesture { openEvent(event) }
                            .contextMenu { rowActions(event) }
                            .id(event.id)
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
                callaEngine.refresh()
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
    }

    /// Events with a video call open the call directly; everything else falls
    /// back to opening the event in the calendar app.
    private func openEvent(_ event: EventModel) {
        guard let url = event.videoCallURL ?? event.calendarAppURL() else { return }
        // Prefer the native meeting app (Zoom/Teams) when the setting is on.
        // Sandbox can't check installation up front, so attempt the app URL and
        // fall back to the browser if no handler accepts it.
        if Defaults[.openMeetingsInApp],
           let native = MeetingLinkResolver.nativeURL(for: url),
           NSWorkspace.shared.open(native) {
            // opened in the native app
        } else {
            openURL(url)
        }

    }

    /// Turns the event's remaining time window into a Pomodoro plan and starts
    /// it, then jumps the notch to the timer.
    private func startPomodoro(for event: EventModel) {
        let preset = PomodoroManager.shared.selectedPreset
        let blocks = PomodoroPlanner.plan(for: event, preset: preset)
        guard !blocks.isEmpty else { return }
        PomodoroManager.shared.start(
            blocks: blocks,
            preset: preset,
            title: event.title,
            sourceEventID: event.id
        )
        BoringViewCoordinator.shared.currentView = .pomodoro
    }

    private func canStartPomodoro(for event: EventModel) -> Bool {
        pomodoroTab && pomodoroCalendarIcon && !event.isAllDay && event.eventStatus != .ended
    }

    /// The actions that used to be glyphs on the row.
    ///
    /// Moved into a right-click rather than deleted: each is still the fastest way
    /// to do its thing from here, and none of them was worth the width. A menu that
    /// comes out empty for an event none of them apply to is fine — macOS shows
    /// nothing rather than an empty box.
    @ViewBuilder
    private func rowActions(_ event: EventModel) -> some View {
        if canPrepCopilot(for: event) {
            Button(hasPrep(for: event) ? "Edit what the copilot knows…" : "Add knowledge…") {
                // Same surface a drop onto the notch lands on, already pointed at
                // this meeting. Two ways in, one place to learn.
                CallaKnowledgeAttach.shared.begin(for: event)
                BoringViewCoordinator.shared.currentView = .knowledgeDrop
                NotificationCenter.default.post(name: .callaKnowledgeWantsNotch, object: nil)
            }
        }
        if canStartPomodoro(for: event) {
            Button("Start a focus timer") { startPomodoro(for: event) }
        }
        if canStartTutor(for: event) {
            if let courseID = CallaCalendarBindings.courseID(for: event.id) {
                Button("Resume the Calla lesson") { startTutor(for: event, courseID: courseID) }
            } else if !callaEngine.status.courses.isEmpty {
                Menu("Start a Calla course") {
                    ForEach(callaEngine.status.courses) { course in
                        Button(course.title) { startTutor(for: event, courseID: course.id) }
                    }
                }
            }
        }
    }

    private func canPrepCopilot(for event: EventModel) -> Bool {
        callaCopilotEnabled && event.videoCallURL != nil && !event.isAllDay
    }

    /// Whether anything has been written for this meeting yet, so the menu can say
    /// "edit" rather than "prep". Read from the app's own cache rather than asked
    /// over XPC per row — the calendar list redraws constantly.
    private func hasPrep(for event: EventModel) -> Bool {
        CallaKnowledgeFocus.shared.hasNotes(eventID: event.id, seriesID: event.seriesID)
    }

    private func canStartTutor(for event: EventModel) -> Bool {
        callaTutorEnabled && callaCalendarEnabled && canStartPomodoro(for: event)
    }

    private func startTutor(for event: EventModel, courseID: String) {
        // Calendar path is atomic from learner perspective: if its time window
        // cannot make a Pomodoro plan, do not start a lesson that claims timer
        // support. Deliberately retain an intentional existing binding.
        let preset = PomodoroManager.shared.selectedPreset
        let blocks = PomodoroPlanner.plan(for: event, preset: preset)
        guard !blocks.isEmpty else {
            callaEngine.reportLocalFailure("This event has no viable Pomodoro window; lesson was not started.")
            BoringViewCoordinator.shared.currentView = .tutor
            return
        }
        CallaCalendarBindings.bind(eventID: event.id, courseID: courseID)
        callaEngine.startCourse(courseID) { status in
            guard status.lastResult == "started" else {
                BoringViewCoordinator.shared.currentView = .tutor
                return
            }
            PomodoroManager.shared.start(
                blocks: blocks,
                preset: preset,
                title: event.title,
                sourceEventID: event.id
            )
            BoringViewCoordinator.shared.currentView = .tutor
        }
    }

    // Soft, leading-aligned color wash behind a card, tinted by the event's calendar.
    private func cardBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.16), color.opacity(0.05), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
    }

    private func eventRow(_ event: EventModel) -> some View {
        let barColor = Color(event.calendar.color)
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            let isPastToday = event.start < Date.now && Calendar.current.isDateInToday(event.start)
            return AnyView(
                HStack(spacing: 9) {
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: barColor
                    )
                    Text(event.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(showFullEventTitles ? nil : 1)
                    Spacer(minLength: 0)
                    Group {
                        if event.isAllDay {
                            Text("all-day")
                                .foregroundColor(barColor)
                        } else {
                            Text(event.start, style: .time)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(cardBackground(barColor))
                .opacity(isCompleted ? 0.4 : (isPastToday ? 0.6 : 1.0))
            )
        } else {
            let isInProgress = event.eventStatus == .inProgress
            let isEnded = event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
            // Computed once per row: the accessor runs NSDataDetector over the
            // event's notes, which is far too expensive to repeat per body pass.
            let videoCallURL = event.videoCallURL
            return AnyView(
                HStack(spacing: 10) {
                    // Full-height status accent — brighter for the event happening now.
                    Rectangle()
                        .fill(barColor)
                        .frame(width: 4)
                        .cornerRadius(2)
                        .opacity(isInProgress ? 1 : 0.85)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(showFullEventTitles ? nil : 1)

                        HStack(spacing: 4) {
                            Group {
                                if event.isAllDay {
                                    Text("all-day")
                                        .fontWeight(.semibold)
                                        .foregroundColor(barColor)
                                } else {
                                    (Text(event.start, style: .time)
                                        + Text(" – ")
                                        + Text(event.end, style: .time))
                                        .foregroundColor(isInProgress ? barColor : .white.opacity(0.5))
                                }
                            }
                            .monospacedDigit()

                            if let location = event.location, !location.isEmpty {
                                Text("·").foregroundColor(.white.opacity(0.3))
                                Text(location)
                                    .foregroundColor(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 9))
                    }
                    Spacer(minLength: 0)
                    // The row's one control.
                    //
                    // The trailing edge used to carry four: a video glyph, a focus
                    // timer and a Calla course picker. At this row height that reads
                    // as a toolbar rather than a list, and the other three are for
                    // things nobody reaches for while scanning what is next — they
                    // are a right-click away instead. Joining the call is what this
                    // row is for, so it is the only thing that gets a button.
                    //
                    // A real Button rather than the glyph it used to be: it is the
                    // primary action of the row, and the row-wide tap gesture is
                    // easy to trigger by accident while scrolling.
                    if videoCallURL != nil {
                        Button {
                            openEvent(event)
                        } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(barColor)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Join this call and start the copilot")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(cardBackground(barColor))
                .opacity(isEnded ? 0.5 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 267, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
