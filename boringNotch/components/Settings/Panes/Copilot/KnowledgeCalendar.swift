//
//  KnowledgeCalendar.swift
//  boringNotch
//

import SwiftUI

/// A month of meetings, so the reader can go and look rather than scroll and hope.
///
/// The list this sits above shows a week back and a month forward, which is the
/// span worth preparing without being asked. But knowledge is attached to
/// meetings that already happened as often as to ones that have not — a summary
/// is filed against the same meeting, and next month's instance reads both — and
/// a flat list could only ever reach as far as it had been told to fetch.
///
/// A day carries two marks and they mean different things: how many meetings it
/// has, and how many of those have something attached. The second is the one
/// worth scanning for, so it is the one that takes the accent.
struct KnowledgeCalendar: View {
    @Binding var month: Date
    @Binding var selectedDay: Date?
    /// day -> (meetings, of which prepared)
    let index: [Date: (meetings: Int, prepared: Int)]

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: NotchSpace.snug) {
            header
            weekdayRow
            grid
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: NotchSpace.tight) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(NotchType.cardTitle)

            if !isCurrentMonth {
                Button("Today") {
                    withAnimation(NotchMotion.settle) {
                        month = calendar.startOfDay(for: Date())
                        selectedDay = nil
                    }
                }
                .buttonStyle(.borderless)
                .font(NotchType.rowDetail)
            }

            Spacer(minLength: 0)

            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous month")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Next month")
        }
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(NotchMotion.settle) {
            month = next
            selectedDay = nil
        }
    }

    // MARK: - Grid

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The week starting on whatever day this locale starts its weeks.
    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var grid: some View {
        let days = gridDays
        return VStack(spacing: 4) {
            ForEach(Array(stride(from: 0, to: days.count, by: 7)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(days[start..<min(start + 7, days.count)], id: \.self) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    /// Whole weeks, so the grid is rectangular; days outside the month are drawn
    /// faintly rather than left as holes.
    private var gridDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading,
                                        to: calendar.startOfDay(for: interval.start))
        else { return [] }
        let count = calendar.dateComponents([.day], from: start, to: interval.end).day ?? 28
        let weeks = Int(ceil(Double(count) / 7.0))
        return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let entry = index[calendar.startOfDay(for: day)]
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false

        return Button {
            withAnimation(NotchMotion.settle) {
                selectedDay = isSelected ? nil : calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(labelStyle(inMonth: inMonth, selected: isSelected, today: isToday))
                marks(for: entry, selected: isSelected)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .fill(Color.effectiveAccent)
                } else if isToday {
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .strokeBorder(Color.effectiveAccent.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(entry == nil)
        .help(helpText(day, entry))
    }

    private func labelStyle(inMonth: Bool, selected: Bool, today: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(.white) }
        if !inMonth { return AnyShapeStyle(.quaternary) }
        if today { return AnyShapeStyle(Color.effectiveAccent) }
        return AnyShapeStyle(.primary)
    }

    /// One dot per meeting up to three, then a count. Prepared meetings take the
    /// accent; the rest stay grey, so "what still needs something" reads at a
    /// glance without having to open anything.
    @ViewBuilder
    private func marks(for entry: (meetings: Int, prepared: Int)?, selected: Bool) -> some View {
        if let entry {
            HStack(spacing: 2) {
                if entry.meetings <= 3 {
                    ForEach(0..<entry.meetings, id: \.self) { i in
                        Circle()
                            .fill(dotStyle(prepared: i < entry.prepared, selected: selected))
                            .frame(width: 4, height: 4)
                    }
                } else {
                    Circle()
                        .fill(dotStyle(prepared: entry.prepared > 0, selected: selected))
                        .frame(width: 4, height: 4)
                    Text("\(entry.meetings)")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                }
            }
            .frame(height: 5)
        } else {
            Color.clear.frame(height: 5)
        }
    }

    private func dotStyle(prepared: Bool, selected: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.white.opacity(prepared ? 1 : 0.5)) }
        return prepared ? AnyShapeStyle(Color.effectiveAccent) : AnyShapeStyle(Color.secondary.opacity(0.55))
    }

    private func helpText(_ day: Date, _ entry: (meetings: Int, prepared: Int)?) -> String {
        guard let entry else { return "" }
        let meetings = "\(entry.meetings) meeting\(entry.meetings == 1 ? "" : "s")"
        return entry.prepared == 0
            ? "\(meetings), nothing attached"
            : "\(meetings), \(entry.prepared) with something attached"
    }
}
