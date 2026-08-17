import AppKit
import SwiftUI

/// Signing in to Google, in the notch.
///
/// This exists because the old flow was invisible: starting a meeting without
/// credentials popped a browser and left the code with nowhere to go, while the
/// app showed a call that was never going to produce a suggestion. The sign-in now
/// happens where the user is already looking, with the steps on screen so a wait
/// is distinguishable from a hang.
///
/// Takes the compact panel — a line of text and a field, not a call.
struct CallaCopilotSignInView: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var code = ""
    @State private var openedURL: String?
    @FocusState private var codeFocused: Bool

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    /// The four moments worth showing. Anything else is detail.
    private enum Step: Int, CaseIterable {
        case checking, browser, code, exchanging

        var title: String {
            switch self {
            // Named for what the user is waiting on: the first stage can be a
            // credential check, which costs a full model round trip.
            case .checking: "Checking"
            case .browser: "Approve in browser"
            case .code: "Paste the code"
            case .exchanging: "Finishing"
            }
        }
    }

    private var stage: String { copilot.agyLoginStage ?? "starting" }

    private var current: Step {
        switch stage {
        case "opening_browser": .browser
        case "awaiting_code": .code
        case "exchanging", "signed_in": .exchanging
        default: .checking
        }
    }

    private var failed: Bool { stage == "failed" }
    private var succeeded: Bool { stage == "signed_in" }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            steps
            if copilot.canAcceptCode || failed { codeRow }
            if let detail = copilot.lastResult, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    // Explicit near-white on a translucent panel: 0.72 disappears
                    // over a light window behind the notch.
                    .foregroundStyle(failed ? Color.orange : Color.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.black.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The notch takes key focus while open, so the field is usable here.
        .onAppear { codeFocused = true }
        .onChange(of: copilot.agyAwaitingCode) { _, awaiting in
            if awaiting { codeFocused = true }
        }
        // The app opens the link, not the engine: an XPC service is not guaranteed
        // a GUI session, so `open` can fail there for reasons retrying cannot fix.
        // Keyed on the URL value, so it opens once per sign-in rather than once per
        // status poll.
        .onChange(of: copilot.agyLoginURL) { _, url in
            guard let url, url != openedURL, let target = URL(string: url) else { return }
            openedURL = url
            NSWorkspace.shared.open(target)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: succeeded ? "checkmark.circle.fill" : failed ? "exclamationmark.triangle.fill" : "person.badge.key.fill")
                .font(.system(size: 11))
                .foregroundStyle(succeeded ? Color.green : failed ? Color.orange : Color.white.opacity(0.85))
            Text(succeeded ? "Signed in" : "Sign in to use this Mac's copilot")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let url = copilot.agyLoginURL {
                Button("Open") { if let target = URL(string: url) { NSWorkspace.shared.open(target) } }
                    .controlSize(.small)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    /// Progress as steps rather than a spinner: a wait the user can place is a
    /// wait they will tolerate.
    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                let done = step.rawValue < current.rawValue || succeeded
                let active = step == current && !succeeded && !failed
                HStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
                        .font(.system(size: 8.5))
                        .foregroundStyle(done ? Color.green : active ? Color.accentColor : Color.white.opacity(0.35))
                    Text(step.title)
                        .font(.system(size: 10, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Color.white.opacity(done ? 0.85 : 0.6))
                        .lineLimit(1)
                        .fixedSize()
                }
                if step != Step.allCases.last {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 1)
                        .frame(maxWidth: 14)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var codeRow: some View {
        HStack(spacing: 8) {
            TextField("Paste the authorization code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($codeFocused)
                .onSubmit(submit)
            Button(failed ? "Retry" : "Submit") {
                if failed, code.trimmingCharacters(in: .whitespaces).isEmpty {
                    engine.loginAgy(force: true)
                } else {
                    submit()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!failed && code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        engine.submitAgyToken(trimmed)
        code = ""
    }
}
