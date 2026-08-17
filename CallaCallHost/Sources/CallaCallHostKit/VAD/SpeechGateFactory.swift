import Foundation
import os.log

private let gateLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "vad")

public enum SpeechGateFactory {
    public static let bundledModelName = "ggml-silero-v5.1.2"

    /// Loads the bundled Silero model.
    ///
    /// Returns nil rather than throwing: without the gate the pipeline still
    /// works, it just spends inference on noise clips. Refusing to start a call
    /// over a missing VAD model would be the worse failure.
    public static func makeBundledGate() async -> SileroVAD? {
        guard let path = Bundle.module.path(forResource: bundledModelName, ofType: "bin") else {
            gateLog.error("bundled Silero model not found; running without the speech gate")
            return nil
        }
        do {
            return try SileroVAD(modelPath: path)
        } catch {
            gateLog.error("Silero init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
