import AppKit
import SwiftUI

private let settingsContentHeight: CGFloat = 600
private let settingsMaximumContentWidth: CGFloat = 1_400

/// Opens the settings window and keeps the one instance of it.
///
/// SwiftUI's `Settings` scene is the obvious way to do this and does not work
/// here. Calla runs as an accessory application — no Dock icon, no menu bar of
/// its own — so there is no Application menu for the standard
/// `showSettingsWindow:` action to travel through, and the scene is never built.
/// Owning the window directly is a few more lines and actually opens.
///
/// The activation policy is raised to `.regular` while the window is up, so it
/// can be reached with ⌘-tab and raised again after being buried; without that,
/// a window belonging to an accessory app can end up behind everything with no
/// way back to it. It drops to `.accessory` again on close, so Calla returns to
/// being just a menu bar item.
@MainActor
final class SettingsPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsPresenter()

    /// Pane-specific SwiftUI fitting sizes must not make Settings jump when a
    /// sidebar row is selected. Keep one deliberate reading height; panes that
    /// need more room provide their own scrolling region.
    private var window: NSWindow?

    func show(host: TutorHostController, settings: TutorSettings) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: SettingsWindow(host: host, settings: settings))
        let window = NSWindow(contentViewController: controller)
        window.title = "Calla Settings"
        // Unified window with a stable reading height. Detail panes scroll their
        // own content rather than moving the window when selection changes.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        // Wider than it was. Courses is a list beside a detail now, and at the
        // old 760 the detail had about 460 points to say everything in.
        window.setContentSize(NSSize(width: 900, height: settingsContentHeight))
        window.contentMinSize = NSSize(width: 780, height: settingsContentHeight)
        window.contentMaxSize = NSSize(width: settingsMaximumContentWidth,
                                       height: settingsContentHeight)
        // `contentMaxSize` alone does not always win against an AppKit hosting
        // view's fitting constraints. Frame limits do, so lock both coordinate
        // systems to the same height and leave only width resizable.
        let minFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 780,
                                                                height: settingsContentHeight)).size
        let maxFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
                                                                width: settingsMaximumContentWidth,
                                                                height: settingsContentHeight)).size
        window.minSize = minFrame
        window.maxSize = maxFrame
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("CallaSettingsWindow")
        window.isRestorable = true
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Back to a menu bar item, which is what Calla is when nobody is
        // configuring it.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Everything Calla can be told, in a window rather than a menu.
///
/// These used to live in a disclosure group inside the menu bar panel, which
/// meant the panel answered two unrelated questions at once — "can Calla teach
/// right now" and "how do I want it to behave" — and had room to do neither
/// properly. The menu keeps what gets acted on; this holds what gets decided.
struct SettingsWindow: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings

    /// A sidebar rather than a tab strip. Tabs were the quick way to get five
    /// panes on screen and they stop scaling at about that many; a sidebar is
    /// also what a Mac owner expects a settings window to look like.
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case connection = "Connection"
        case courses = "Courses"
        case applications = "Applications"
        case permissions = "Permissions"
        case shortcuts = "Shortcuts"
        case logs = "Logs"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gear"
            case .connection: return "antenna.radiowaves.left.and.right"
            case .courses: return "books.vertical"
            case .applications: return "app.badge.checkmark"
            case .permissions: return "lock.shield"
            case .shortcuts: return "keyboard"
            case .logs: return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var selected: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selected) { pane in
                // This split view chooses its detail directly from `selected`.
                // A value-based NavigationLink also asks SwiftUI to find a
                // navigationDestination for Pane, which does not exist here
                // and produces its runtime navigation error when a sidebar row
                // is clicked. A tagged row is the native selection control and
                // leaves this single source of truth intact.
                Label(pane.rawValue, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(196)
        } detail: { detail }
        // Never let an individual pane publish its full intrinsic height to the
        // hosting window. Tall panes scroll inside this stable viewport.
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 780, maxWidth: settingsMaximumContentWidth,
               minHeight: settingsContentHeight, maxHeight: settingsContentHeight)
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch selected {
            case .general:
                paneScroll { GeneralPane(settings: settings) }
            // Connection, Courses and Logs each own their scrolling region: a
            // list beside a detail, and a lazily rendered log tail, cannot be
            // wrapped in a second scroll view without losing the thing that
            // makes them work.
            case .connection:
                ConnectionPane(host: host, settings: settings)
            case .courses:
                CoursesPane(host: host, settings: settings)
            case .applications:
                paneScroll { ApplicationsPane(settings: settings) }
            case .permissions:
                paneScroll { PermissionsPane(settings: settings) }
            case .shortcuts:
                paneScroll { ShortcutsPane() }
            case .logs:
                LogsPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(selected.rawValue)
    }

    private func paneScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - General

/// How Calla behaves while it is teaching.
///
/// The Gateway check used to sit at the top of this pane, which put "can this
/// Mac reach Calla at all" in the same list as how wide the lesson card is
/// drawn. It has a pane of its own now.
private struct GeneralPane: View {
    @ObservedObject var settings: TutorSettings

    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                setting("Detail Calla sees",
                        // The measured cost, said where the choice is made. A
                        // capture is the most expensive thing in a teaching step
                        // by some distance, and nothing in the interface used to
                        // admit that.
                        "One 1600-pixel capture costs about 27,000 tokens of Calla's attention and around 13 seconds of it reading. At 1024 that is roughly 40% of the pixels and interface labels are still legible. Turn it up only for an application with genuinely tiny text.") {
                    Picker("", selection: $settings.captureLongEdge) {
                        ForEach(TutorSettings.captureLongEdgeChoices, id: \.self) { edge in
                            Text("\(edge) px").tag(edge)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                setting("Pointer size",
                        "How big Calla's pointer is drawn. Larger is easier to follow on a dense interface; smaller covers less of it.") {
                    Picker("", selection: $settings.cursorSize) {
                        ForEach(TutorSettings.cursorSizeChoices, id: \.self) { size in
                            Text(Self.cursorLabel(size)).tag(size)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    // Live, so the choice can be judged by looking at it rather
                    // than by starting a lesson and waiting for the next step.
                    .onChange(of: settings.cursorSize) { _, size in
                        PointerOverlay.shared.setCursorSize(size)
                    }
                }

                setting("Lesson card width",
                        "How much of a line a step's words get. Calla's pointer and card only ever appear over the application being taught, never anywhere else.") {
                    Picker("", selection: $settings.tooltipWidth) {
                        ForEach(TutorSettings.tooltipWidthChoices, id: \.self) { width in
                            Text("\(width)").tag(width)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    // Live, like the pointer size: a width is judged by reading
                    // a real step at it, not by picking a number.
                    .onChange(of: settings.tooltipWidth) { _, width in
                        PointerOverlay.shared.setTooltipWidth(width)
                    }
                }

                setting("Tooltip opacity",
                        "A slightly translucent tooltip leaves more of the interface visible without making the words hard to read.") {
                    Picker("", selection: $settings.tooltipOpacity) {
                        ForEach(TutorSettings.tooltipOpacityChoices, id: \.self) { opacity in
                            Text("\(Int(opacity * 100))%").tag(opacity)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: settings.tooltipOpacity) { _, opacity in
                        PointerOverlay.shared.setTooltipOpacity(opacity)
                    }
                }

            } header: {
                Text("What Calla draws")
            }

            Section {
                // "Put the tooltip away when a lesson goes quiet" was here and
                // has been removed rather than reworded. It wrote a preference
                // nothing read, and the overlay renderer has no notion of idle
                // at all, so the switch had never once done anything. A control
                // that lies is worse than a missing one: it spends the owner's
                // trust in every other control on the pane.
                toggle("Hide the tooltip while my pointer is over it", $settings.hideTooltipOnHover,
                       "The pointer itself never hides.")
                toggle("Status capsule", $settings.showStatusHUD,
                       "The small capsule naming what Calla is doing.")
            } header: {
                Text("Behaviour")
            }

            Section {
                Button("Reset appearance and behaviour") { confirmingReset = true }
            } footer: {
                // It used to reset the allowlist too, silently and without
                // asking, which left Calla unable to teach anything and gave no
                // hint that this button was why.
                Text("The applications you allow are not touched. Allowing an application is a decision about what Calla may look at rather than a preference, and each is removed on its own in Applications.")
                    .font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Put appearance and behaviour back to their defaults?",
                            isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Capture detail, pointer size, card width, opacity and the two behaviour switches return to what Calla ships with. Allowed applications, permissions and course progress are untouched.")
        }
    }

    private func setting<Content: View>(_ title: String, _ detail: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(CallaFont.rowTitle)
            content()
            Text(detail).font(CallaFont.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(title, isOn: binding).font(CallaFont.body)
            Text(detail).font(CallaFont.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private static func cursorLabel(_ size: Int) -> String {
        switch size {
        case 24: return "Small"
        case 38: return "Large"
        default: return "Medium"
        }
    }
}

// MARK: - Applications

private struct ApplicationsPane: View {
    @ObservedObject var settings: TutorSettings

    /// What is in front right now.
    ///
    /// Recomputed on a timer, because the whole point of the control below is to
    /// allow the application you just switched away from — and this was read
    /// once when the pane was built, so it named whatever happened to be
    /// frontmost then and never changed its mind again.
    @State private var candidate: (name: String, bundleID: String)?
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calla may look at these applications, and nothing else. A lesson can narrow this list; it can never widen it.")
                .font(CallaFont.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.allowedBundleIDs.isEmpty {
                Label("No application allowed yet, so Calla cannot teach anything.",
                      systemImage: "exclamationmark.triangle")
                    .font(CallaFont.body).foregroundStyle(CallaTint.attention)
            }

            List {
                ForEach(settings.allowedBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        AppIcon(bundleID: bundleID, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(settings.displayName(for: bundleID)).font(CallaFont.body)
                            Text(bundleID).font(CallaFont.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Remove") { settings.disallow(bundleID: bundleID) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 200)

            if let candidate, !settings.allowedBundleIDs.contains(candidate.bundleID) {
                Button {
                    settings.allow(bundleID: candidate.bundleID)
                } label: {
                    Label("Allow \(candidate.name)", systemImage: "plus.circle")
                }
            } else {
                Text("Bring the application you want to add to the front, then come back here.")
                    .font(CallaFont.detail).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .onAppear { candidate = settings.frontmostCandidate() }
        .onReceive(tick) { _ in candidate = settings.frontmostCandidate() }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @ObservedObject var settings: TutorSettings

    var body: some View {
        Form {
            Section {
            permission(
                granted: settings.screenRecordingGranted,
                title: "Screen Recording",
                detail: "Required. Calla reads one window at a time, only from the applications you allowed. Without it there is nothing to teach from.",
                action: ("Open Settings", { settings.requestScreenRecordingApproval() }))

            permission(
                granted: settings.accessibilityGranted,
                title: "Accessibility",
                // Not a scold — a measured offer. This is the difference between
                // a step landing in a tenth of a second and one waiting on a
                // round trip to the Gateway.
                detail: "Optional, and worth it. With Accessibility, Calla finds the next control on this Mac and points at it in about a tenth of a second; without it every step waits on the Gateway instead. It still cannot click anything without your separate, per-action approval.",
                action: ("Open Settings", { settings.requestAccessibilityApproval() }))
            } header: {
                Text("What Calla is allowed to do")
            }

            Section {
                Text("Calla holds no provider credentials on this Mac and is not meant to. The thinking happens on the Gateway; the screen, the coordinates and every action stay here.")
                    .font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await settings.refreshPermissionStatus() }
    }

    private func permission(granted: Bool, title: String, detail: String,
                            action: (String, () -> Void)) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CallaStatusIcon(ok: granted, size: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(CallaFont.rowTitle)
                Text(detail).font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !granted {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
    }
}

// MARK: - Shortcuts

/// The keys that exist, which is not the list this pane used to print.
///
/// It advertised ⌥⌘. for Stop, which the renderer deliberately does not register
/// — a shortcut nobody can see is one nobody presses on purpose, only by
/// accident, ending a lesson mid-step. And it omitted ⌥⌘L, which *is* registered
/// and which the menu bar's own help text offers, so the one binding a learner
/// might meet without warning was the one binding with no explanation anywhere.
private struct ShortcutsPane: View {
    @ObservedObject var status = ShortcutStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Answering Calla without reaching for the menu bar. A lesson's own keys are held only while a lesson is on screen, so they collide with the application being taught for no longer than that.")
                .font(CallaFont.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            shortcut("⌥⌘/", "Ask Calla",
                     "Held whenever Calla is running, because it is how a lesson starts — a key that works only once a lesson exists cannot begin one. Opens over the application you were last working in.")
            shortcut("⌥⌘↩", "I did that",
                     "Tells Calla you finished the step. Held only while a lesson is on screen; the Mac usually answers this for you.")
            shortcut("⌥⌘L", "Back to lesson",
                     "Returns to the step you were on after stepping out to ask something. Held only while a lesson is on screen.")

            if !status.unavailable.isEmpty {
                Divider()
                Label("Another application already owns \(status.unavailable.joined(separator: ", ")), so Calla could not claim \(status.unavailable.count == 1 ? "it" : "them").",
                      systemImage: "exclamationmark.triangle")
                    .font(CallaFont.detail).foregroundStyle(CallaTint.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("These are not editable yet.")
                .font(CallaFont.detail).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(20)
    }

    private func shortcut(_ keys: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(width: 52, alignment: .leading)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CallaFont.rowTitle)
                Text(detail).font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Which key combinations Calla asked for and did not get.
///
/// The renderer has reported this since shortcuts were introduced — it refuses
/// to swallow a combination another application already owns, on the grounds
/// that a shortcut which silently does nothing is worse than none — and the host
/// dropped the message on the floor. Nothing has ever shown it to anybody.
@MainActor
final class ShortcutStatus: ObservableObject {
    static let shared = ShortcutStatus()

    @Published private(set) var unavailable: [String] = []

    func note(unavailable value: String) {
        let combos = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !combos.isEmpty else { return }
        unavailable = Array(Set(unavailable).union(combos)).sorted()
    }
}
