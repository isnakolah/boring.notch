import AppKit
import SwiftUI

/// Calla's logs, readable without leaving Calla.
///
/// "Open the folder in Finder" was the whole feature, which meant the answer to
/// "why did that step not work" lived in a plain-text file the owner had to know
/// how to read. Three of these four are freeform notes; `step-timing.log` is
/// columnar and is the one that actually answers that question, so it is parsed
/// rather than dumped.
///
/// Nothing here leaves the Mac, and nothing is written — the viewer only reads.
enum CallaLog: String, CaseIterable, Identifiable {
    case stepTiming = "step-timing.log"
    case host = "tutor-host.log"
    case node = "node-host.log"
    case overlay = "overlay.log"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stepTiming: return "Steps"
        case .host: return "Host"
        case .node: return "Node"
        case .overlay: return "Overlay"
        }
    }

    /// What this file is for, so the picker does not require prior knowledge.
    var detail: String {
        switch self {
        case .stepTiming: return "How long each step took, and why one was handed back to Calla."
        case .host: return "The Mac host: shortcuts, permissions, lessons starting and stopping."
        case .node: return "The link to the Gateway."
        case .overlay: return "The pointer and tooltip renderer."
        }
    }

    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Calla")
    }

    var url: URL { Self.directory.appendingPathComponent(rawValue) }
}

/// One line, with whatever structure could be recovered from it.
struct LogLine: Identifiable {
    let id: Int
    let raw: String
    /// Leading ISO timestamp, when the line carries one.
    let stamp: String?
    /// `host` or `send` in the timing log — who measured it.
    let source: String?
    let operation: String?
    let duration: String?
    let outcome: String?
    /// The remainder, for lines with no columns to speak of.
    let message: String?

    /// Worth surfacing when the owner only wants to see what went wrong.
    ///
    /// A refusal and a hand-back are the two outcomes that cost the learner
    /// something, and both are ordinary English in these files rather than a
    /// level field, so they are matched as text.
    var isProblem: Bool {
        let haystack = (outcome ?? message ?? raw).lowercased()
        // Deliberately narrow. A list that also matched "stand" flagged every
        // "standard", and one that matched "fail" flagged nothing extra over
        // "failed" — a problems filter that shows two thirds of the file is not a
        // filter.
        for needle in ["refused", "handed back", "error", "failed", "denied",
                       "not permitted", "unavailable", "timed out", "could not",
                       "standing down", "ignored"] {
            if haystack.contains(needle) { return true }
        }
        return false
    }

    /// `<stamp> host observe 98.3ms ok`, or `… advance_local 41.8ms handed back — why`.
    ///
    /// Anything that does not match that shape keeps its text whole rather than
    /// being forced into columns it does not have.
    static func parse(_ raw: String, id: Int) -> LogLine {
        let fields = raw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
        let looksTimestamped = fields.first?.count == 20 && fields.first?.hasSuffix("Z") == true
        guard looksTimestamped else {
            return LogLine(id: id, raw: raw, stamp: nil, source: nil, operation: nil,
                           duration: nil, outcome: nil, message: raw)
        }
        guard fields.count >= 5,
              fields[3].hasSuffix("ms") else {
            return LogLine(id: id, raw: raw, stamp: fields[0], source: nil, operation: nil,
                           duration: nil, outcome: nil,
                           message: fields.dropFirst().joined(separator: " "))
        }
        return LogLine(id: id, raw: raw, stamp: fields[0], source: fields[1], operation: fields[2],
                       duration: fields[3], outcome: fields[4], message: nil)
    }
}

/// Tails one log file, cheaply and on a timer.
///
/// Bounded on purpose: these files grow without limit and only the recent end of
/// one has ever been useful. Re-read on a timer rather than watched with a file
/// descriptor, because a rotated or truncated file quietly breaks a watch and
/// nobody notices until they need the log.
@MainActor
final class LogTail: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var missing = false

    /// Enough to cover a long lesson, small enough to re-read every second.
    private let window = 256 * 1024

    private var log: CallaLog = .stepTiming
    private var timer: Timer?
    private var lastSignature: String?

    func follow(_ log: CallaLog) {
        if log != self.log {
            self.log = log
            lastSignature = nil
            lines = []
        }
        reload()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reveal the folder, for anything this viewer is the wrong shape for.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([log.url])
    }

    private func reload() {
        guard let handle = try? FileHandle(forReadingFrom: log.url) else {
            if !missing { missing = true; lines = [] }
            return
        }
        defer { try? handle.close() }
        missing = false
        let size = (try? handle.seekToEnd()) ?? 0
        // Nothing has been appended and nothing has been rotated away.
        let signature = "\(size)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return }
        var parsed: [LogLine] = []
        // A window that starts mid-file almost always starts mid-line; drop it
        // rather than showing a fragment as though it were a record.
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (offset, row) in rows.enumerated() {
            if offset == 0 && start > 0 { continue }
            parsed.append(LogLine.parse(String(row), id: offset))
        }
        lines = parsed
    }
}

/// The Logs tab.
struct LogsPane: View {
    /// Constructing and following a tail reads a bounded chunk from disk. Keep
    /// that work out of Settings launch and out of every other sidebar pane.
    @State private var mounted = false

    var body: some View {
        Group {
            if mounted {
                LoadedLogsPane()
            } else {
                ProgressView("Loading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Yield first so sidebar selection and its layout complete before
            // disk I/O and log parsing start on the main actor.
            guard !mounted else { return }
            DispatchQueue.main.async { mounted = true }
        }
    }
}

/// Actual log reader. Deliberately created only after `LogsPane` has appeared.
private struct LoadedLogsPane: View {
    @StateObject private var tail = LogTail()
    @State private var selection: CallaLog = .stepTiming
    @State private var filter = ""
    @State private var problemsOnly = false
    /// Stop chasing the tail when the owner has scrolled back to read something.
    @State private var following = true

    private var visible: [LogLine] {
        tail.lines.filter { line in
            if problemsOnly && !line.isProblem { return false }
            guard !filter.isEmpty else { return true }
            return line.raw.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selection) {
                ForEach(CallaLog.allCases) { log in Text(log.title).tag(log) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selection.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle("Problems only", isOn: $problemsOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Toggle("Follow", isOn: $following)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Button("Reveal") { tail.revealInFinder() }
                    .controlSize(.small)
            }

            rows
        }
        .padding(16)
        .onAppear { tail.follow(selection) }
        .onDisappear { tail.stop() }
        .onChange(of: selection) { _, log in tail.follow(log) }
    }

    @ViewBuilder private var rows: some View {
        if tail.missing {
            placeholder("Nothing here yet — \(selection.rawValue) has not been written.")
        } else if visible.isEmpty {
            placeholder(problemsOnly ? "No problems in what is on file." : "No lines match.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { row(for: $0) }
                        // Anchor for following the tail.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: visible.count) { _, _ in
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    guard following else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
    }

    /// The timestamp recedes, the operation carries, and a bad outcome is the only
    /// coloured thing on the line — so a page of these can be skimmed for trouble
    /// without reading any of it.
    private func row(for line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let stamp = line.stamp {
                Text(Self.clockTime(stamp))
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
            }
            if let operation = line.operation {
                Text(operation)
                    .fontWeight(.medium)
                    .frame(width: 116, alignment: .leading)
                Text(line.duration ?? "")
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .trailing)
                Text(line.outcome ?? "")
                    .foregroundStyle(line.isProblem ? Color.orange : Color.secondary)
            } else {
                Text(line.message ?? line.raw)
                    .foregroundStyle(line.isProblem ? Color.orange : Color.primary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    /// `2026-08-12T13:01:50Z` reads as `13:01:50`. The date is almost always today
    /// and repeating it on every line crowds out the part that varies.
    private static func clockTime(_ stamp: String) -> String {
        guard let t = stamp.firstIndex(of: "T") else { return stamp }
        let rest = stamp[stamp.index(after: t)...]
        return String(rest.prefix(8))
    }
}
