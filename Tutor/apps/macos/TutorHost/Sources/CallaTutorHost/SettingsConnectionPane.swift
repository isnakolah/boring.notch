import AppKit
import SwiftUI

/// Whether this Mac is plugged into Calla's intelligence, and what it last said.
///
/// All of this was already being tracked and none of it was anywhere a person
/// could look. `BackendStatus` has published the link, when it stopped being
/// healthy, the last operation and when it arrived since it was written; the
/// host has published its own socket status; the relay holds the Tailscale
/// approval link. Settings showed one on-demand check, wedged into General
/// between capture detail and tooltip opacity, and the menu bar showed a single
/// coloured dot. When a lesson would not start, neither answered why.
struct ConnectionPane: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings
    @ObservedObject var backend = BackendStatus.shared
    @ObservedObject var relay = LessonRelay.shared
    @ObservedObject var gatewayCheck = GatewayCheck.shared

    /// Redrawn on a timer because every relative time on this pane — "4s ago",
    /// "stuck for 2m" — is otherwise only as fresh as the last thing that
    /// happened to change a published value, which during an outage is nothing.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                linkCard

                if let url = relay.authorisationURL {
                    authorisationCard(url)
                }

                if let problem = backend.problem {
                    problemCard(problem)
                }

                captureCard
                gatewayCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        // `BackendStatus` polls only while somebody is looking. Without holding
        // a place in that count this pane shows whatever the link happened to be
        // when it opened, forever.
        .onAppear { backend.observers += 1; backend.refresh() }
        .onDisappear { backend.observers = max(0, backend.observers - 1) }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - The link

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CallaGlyph(symbol: linkSymbol, tint: linkTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(linkTitle).font(CallaFont.cardTitle)
                    Text(linkDetail).font(CallaFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle().fill(linkTint).frame(width: 8, height: 8).padding(.top, 6)
            }

            Divider()

            // The two facts that tell a quiet link from a broken one apart.
            if let at = backend.lastRequestAt {
                CallaStatusLine(title: "Last heard from the Gateway", ok: true,
                                value: "\(backend.lastOperation ?? "a request") · \(CallaTime.ago(at, now: now))")
            } else {
                CallaStatusLine(title: "The Gateway has not sent anything yet", ok: false)
            }
            CallaStatusLine(title: "This Mac's socket", ok: host.status.contains("ready"),
                            value: host.status)
        }
        .callaCard(tint: linkTint == CallaTint.healthy ? nil : linkTint)
    }

    private func authorisationCard(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(CallaTint.attention).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calla needs one Tailscale approval").font(CallaFont.rowTitle)
                Text("Reaching the Gateway asks for a browser check when the session expires.")
                    .font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open") {
                NSWorkspace.shared.open(url)
                relay.clearAuthorisation()
            }
            .controlSize(.small)
        }
        .callaCard(tint: CallaTint.attention)
    }

    private func problemCard(_ problem: BackendStatus.Problem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CallaTint.attention).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.summary).font(CallaFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                // The code belongs in the log, and this is the one window where
                // somebody might actually want to search for it.
                Text("\(problem.detail) · \(CallaTime.ago(problem.at, now: now))")
                    .font(CallaFont.caption).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { backend.clearProblem() }.controlSize(.small)
        }
        .callaCard(tint: CallaTint.attention)
    }

    // MARK: - Capture

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $host.captureActive) {
                Text("Watch the screen").font(CallaFont.rowTitle)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            // The same published value the menu bar's footer binds to, so the
            // two cannot drift. It was reachable only from the menu, which made
            // the most consequential switch in Calla the one thing Settings had
            // nothing to say about.
            Text("When this is off no capture is taken and nothing reaches the Gateway. It does not end a lesson — stopping does that.")
                .font(CallaFont.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .callaCard()
    }

    // MARK: - Gateway check

    private var gatewayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check the Gateway").font(CallaFont.cardTitle)
                    Text("A read-only probe over Calla's existing private Tailscale SSH path. No lesson, capture, or course is changed by it.")
                        .font(CallaFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(gatewayCheck.running ? "Checking…" : "Check") { gatewayCheck.run() }
                    .controlSize(.small)
                    .disabled(gatewayCheck.running)
            }

            if let result = gatewayCheck.result {
                Divider()
                Text(result.summary).font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CallaStatusLine(title: "Gateway", ok: result.gateway == true)
                CallaStatusLine(title: "Tutor plugin", ok: result.plugin == true)
                CallaStatusLine(title: "Course control", ok: result.courseControl == true,
                                value: result.courseControl == true ? nil : "Not configured on this Gateway")
            } else if let failure = gatewayCheck.failure {
                Divider()
                Text(failure).font(CallaFont.detail).foregroundStyle(CallaTint.stuck)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .callaCard()
    }

    // MARK: - Reading the link

    private var linkTitle: String {
        switch backend.link {
        case .connected: return "Connected"
        case .agentNotRunning: return "Calla's node agent is not running"
        case .disconnected: return backend.isStuck ? "Can't reach Calla" : "Reconnecting…"
        case .unknown: return backend.isStuck ? "Can't reach Calla" : "Connecting…"
        }
    }

    private var linkDetail: String {
        switch backend.link {
        case .connected(let gateway):
            return "Talking to \(gateway). The thinking happens there; the screen, the coordinates and every action stay on this Mac."
        case .agentNotRunning:
            return "Nothing is holding the connection to the Gateway, so no lesson can start. Its log is in Logs › Node."
        case .disconnected(let reason):
            return stalledFor.map { "\(sentence(reason)) Retrying for \($0)." } ?? "\(sentence(reason)) Calla retries on its own."
        case .unknown:
            return "No connection has been reported yet. This is what it says before the node agent has logged anything."
        }
    }

    /// Red is reserved for stopped. An ordinary reconnect is orange, however
    /// alarming it looks, because it usually resolves itself.
    private var linkTint: Color {
        if backend.link.isHealthy { return CallaTint.healthy }
        return backend.isStuck ? CallaTint.stuck : CallaTint.attention
    }

    private var linkSymbol: String {
        backend.link.isHealthy
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
    }

    private var stalledFor: String? {
        guard let since = backend.unhealthySince else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        return "\(first.uppercased())\(reason.dropFirst())."
    }
}
