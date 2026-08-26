# Security Policy

## Reporting a Vulnerability

The Bored Team and community take security bugs in Boring Notch seriously. We appreciate your efforts to responsibly disclose your findings, and will make every effort to acknowledge your contributions.

To report a security issue, please use the GitHub Security Advisory ["Report a Vulnerability"](https://github.com/TheBoredTeam/boring.notch/security/advisories/new) tab.

The Bored Team will send a response indicating the next steps in handling your report. After the initial reply to your report, we will keep you informed of the progress towards a fix and full announcement, and may ask for additional information or guidance.

Report security bugs in third-party dependencies to the person or team maintaining the package or dependency.

## Tutor captures and intelligence

- Boring Engine owns Tutor run state, encrypted capture history, provider routing and progression. TutorHost never persists captures in Engine mode; Gateway never receives Tutor action or verification authority.
- Screenshot capture is limited to focused allowlisted target window. Missing Screen Recording permission, changed focus/window identity, protected/blank/oversized content and failed validation reject capture. No display fallback.
- Boring encrypts persisted JPEG captures with AES-GCM using this-device-only Keychain key. Capture and pending sanitized history commit before provider transmission. Missing/wrong key or storage failure blocks feedback and sends nothing.
- Local `agy` is process-local, not on-device inference: it can transmit target-window screenshots to Google Antigravity-backed remote models. Gateway feedback can also transmit screenshots to configured provider. Provider-side retention is outside Boring deletion control.
- Model replies are bounded feedback JSON only. They cannot choose a target, send Host commands, perform actions, determine pass/fail, or advance a lesson.
