import Defaults
import SwiftUI

/// Which model hears the call, and whether it is on this Mac yet.
///
/// The download used to be invisible: the first call on a new machine blocked
/// for minutes pulling half a gigabyte while the notch showed "Ready". The
/// capture host reports its progress now, so the wait is at least a wait you
/// can see — and can start before the meeting instead of during it.
struct CopilotTranscriptionPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @Default(.callaCopilotLiveModel) private var model
    @Default(.callaCopilotArchiveRetranscribe) private var archiveRetranscribe

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotTranscription) {
            liveModelCard
            downloadCard
            archiveCard
        }
        .task { engine.refresh() }
    }

    private var liveModelCard: some View {
        SettingCard("Live model",
                    detail: "Runs during the call. Small hears more accurately; base keeps up on a busy machine.") {
            VStack(spacing: 12) {
                Picker("", selection: $model) {
                    Text("Small").tag("whisper-small-en")
                    Text("Base").tag("whisper-base-en")
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                SettingRow("Fetch it now",
                           detail: "Downloads ahead of a call instead of at the start of one.") {
                    Button("Download") { engine.prefetchModel(model) }
                        .controlSize(.small)
                        .disabled(!copilot.available || copilot.modelDownload?.isActive == true)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadCard: some View {
        if let download = copilot.modelDownload {
            SettingCard("Model download",
                        tint: download.state == "failed" ? NotchTint.attention
                            : download.isActive ? NotchTint.active : nil) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingFact(title: "Model", value: download.model)
                    SettingFact(title: "State", value: stateLabel(download.state),
                                tint: download.state == "failed" ? NotchTint.attention
                                    : download.isActive ? NotchTint.active : NotchTint.healthy)
                    if download.totalBytes > 0 {
                        SettingProgressBar(
                            done: megabytes(download.receivedBytes),
                            total: megabytes(download.totalBytes),
                            active: download.isActive)
                    }
                    if let message = download.message {
                        Text(message)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var archiveCard: some View {
        SettingCard("After the call",
                    detail: "The live model trades accuracy for keeping up. The archive model has no such constraint once the call is over.") {
            SettingRow("Re-transcribe automatically",
                       detail: "Runs the large model over the saved audio when a call ends. Slower, and more accurate. Individual calls can also be re-run from History.") {
                Toggle("", isOn: $archiveRetranscribe).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "downloading": return "Downloading"
        case "verifying": return "Verifying"
        case "ready": return "On this Mac"
        case "failed": return "Failed"
        default: return state
        }
    }

    /// The progress bar counts things, so the thing is a megabyte.
    private func megabytes(_ bytes: Int64) -> Int {
        Int(bytes / 1_048_576)
    }
}
