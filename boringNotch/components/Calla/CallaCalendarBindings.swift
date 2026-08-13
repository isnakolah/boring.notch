import Defaults
import Foundation

struct CallaCalendarBinding: Codable, Equatable, Identifiable {
    let eventID: String
    let courseID: String

    var id: String { eventID }
}

enum CallaCalendarBindings {
    static var all: [CallaCalendarBinding] {
        guard let data = Defaults[.callaCalendarBindings],
              let bindings = try? JSONDecoder().decode([CallaCalendarBinding].self, from: data) else { return [] }
        return bindings.filter { !$0.eventID.isEmpty && !$0.courseID.isEmpty }
    }

    static func courseID(for eventID: String) -> String? {
        all.first(where: { $0.eventID == eventID })?.courseID
    }

    static func bind(eventID: String, courseID: String) {
        guard !eventID.isEmpty, !courseID.isEmpty else { return }
        var next = all.filter { $0.eventID != eventID }
        next.append(CallaCalendarBinding(eventID: eventID, courseID: courseID))
        Defaults[.callaCalendarBindings] = try? JSONEncoder().encode(next)
    }

    static func remove(eventID: String) {
        Defaults[.callaCalendarBindings] = try? JSONEncoder().encode(all.filter { $0.eventID != eventID })
    }
}
