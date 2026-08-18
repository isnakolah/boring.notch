import Foundation

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func requestScreenRecording(with reply: @escaping (Data) -> Void)
    func requestAccessibility(with reply: @escaping (Data) -> Void)
    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void)
    func resumeCourse(with reply: @escaping (Data) -> Void)
    func stopLesson(with reply: @escaping (Data) -> Void)
    func ask(_ text: String, with reply: @escaping (Data) -> Void)
    /// Owner UI sends a typed, bounded course-control command. The engine
    /// validates it before it can reach Boring's bundled private script.
    func courseControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Owner UI starts, stops, or re-targets the live call copilot. The engine
    /// validates the command, then drives the unsandboxed capture host that
    /// owns the microphone and screen-recording grants.
    func copilotControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Turns of the current call newer than `seq`; -1 asks for the whole tail.
    ///
    /// One of the few methods here that does not reply with `Status`. A
    /// transcript is far too large to ride the two-second status poll, and the
    /// notch app is sandboxed, so it cannot read the capture host's files
    /// itself — this is the only way that text reaches the UI. The cursor keeps
    /// the live panel's sub-second poll cheap: past the first read it almost
    /// always returns an empty array.
    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void)
    /// Every call this Mac has archived, newest first. Replies with
    /// `[CallSummary]`, not `Status`.
    func copilotCalls(with reply: @escaping (Data) -> Void)
    /// One archived call's full transcript. Replies with `[CallTurn]`.
    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void)
    /// What the copilot returned during that call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void)
    /// Runs the capture host's `permissions` subcommand so the microphone and
    /// screen-recording prompts are attributed to the host's own signature.
    ///
    /// Asking from inside this service would prompt for — and grant to — the
    /// engine, which is not the process that captures anything. Same shape as
    /// the fix already applied to the Tutor host.
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void)
    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void)
    /// Create, edit, delete or list knowledge notes.
    ///
    /// The store lives on this side of the sandbox line, so every edit the app
    /// makes is one of these rather than a file write.
    func knowledgeControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Calls recorded against a calendar event, or its whole recurring series.
    func copilotCallsForEvent(_ query: Data, with reply: @escaping (Data) -> Void)
}
