//
//  PomodoroView.swift
//  boringNotch
//
//  The open-notch Pomodoro section. Two states share one frame: an idle state
//  that give focus timer its own compact cockpit. Whole section fits inside
//  roughly 488x100pt beneath notch header.
//

import AppKit
import Defaults
import SwiftUI

struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @Default(.pomodoroPresets) private var presets
    @Default(.pomodoroSelectedPresetID) private var selectedPresetID

    @State private var customMinutes: Int = 25
    @State private var showingCustom = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        Group {
            if pomodoro.isActive {
                runningView
            } else {
                idleView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .animation(.smooth(duration: 0.3), value: pomodoro.isActive)
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                phaseStatus
                Spacer(minLength: 8)
                todayStats
            }

            HStack(alignment: .center, spacing: 12) {
                countdown
                titleField
                transportControls
            }

            phaseProgressBar
        }
    }

    private var phaseStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: pomodoro.statusIcon)
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect)
            Text(pomodoro.runState == .paused ? "PAUSED" : pomodoro.phase.title.uppercased())
                .tracking(0.45)
            if pomodoro.phase.isWork {
                Text("BLOCK \(pomodoro.completedWorkBlocks + 1)")
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(phaseTint)
    }

    private var countdown: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text("REMAINING")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.45)
            Text(twoUnitString(pomodoro.remaining))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(isFinalStretch ? .red : .white)
                .animation(.smooth(duration: 0.25), value: pomodoro.remaining)
                .fixedSize()
        }
        .fixedSize()
    }

    private var transportControls: some View {
        HStack(spacing: 5) {
            Button(action: pomodoro.toggle) {
                Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(phaseTint))
            }
            .buttonStyle(.plain)
            .help(pomodoro.isRunning ? "Pause timer" : "Resume timer")

            secondaryControl(icon: "forward.end.fill", help: "Skip phase", action: pomodoro.skip)
            secondaryControl(icon: "arrow.counterclockwise", help: "Reset phase", action: pomodoro.reset)
            secondaryControl(icon: "stop.fill", help: "Stop timer", action: pomodoro.stop)
        }
        .foregroundStyle(.white)
        .fixedSize()
    }

    private func secondaryControl(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.78))
        .help(help)
    }

    private var phaseProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(phaseTint)
                    .frame(width: max(0, geometry.size.width * pomodoro.progress))
            }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.3), value: pomodoro.progress)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.effectiveAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Start focus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Pick a session length")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer(minLength: 8)
                todayStats
            }

            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    presetChip(preset)
                }

                customChip

                Spacer(minLength: 0)
            }

            if showingCustom {
                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Stepper(value: $customMinutes, in: 1...240, step: 5) {
                        Text("\(customMinutes) min")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .fixedSize()

                    Button {
                        pomodoro.startCustom(minutes: customMinutes)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.effectiveAccent)
                    .controlSize(.small)
                }
                .padding(.leading, 2)
            }
        }
    }

    private func presetChip(_ preset: PomodoroPreset) -> some View {
        Button {
            selectedPresetID = preset.id
            showingCustom = false
            pomodoro.start(preset: preset)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.chipLabel)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(preset.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(preset.id == selectedPresetID ? .white.opacity(0.75) : .white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(preset.id == selectedPresetID ? Color.effectiveAccent.opacity(0.34) : Color.white.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(preset.id == selectedPresetID ? Color.effectiveAccent.opacity(0.8) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var customChip: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { showingCustom.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Custom")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: showingCustom ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("What are you working on?", text: $pomodoro.sessionTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .focused($titleFieldFocused)
                .lineLimit(1)
                // This overlay stays in layout before and after focus. The
                // previous conditional ZStack layer changed intrinsic width
                // when it disappeared, which made cockpit controls jump.
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!titleFieldFocused)
                        .onTapGesture {
                            NSApp.activate(ignoringOtherApps: true)
                            DispatchQueue.main.async { titleFieldFocused = true }
                        }
                }
                .onSubmit { titleFieldFocused = false }

            Rectangle()
                .fill(.white.opacity(titleFieldFocused ? 0.35 : 0.12))
                .frame(height: 1)
        }
        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
    }

    private var todayStats: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("TODAY")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.4)

            HStack(spacing: 4) {
                Text("\(pomodoro.todayCompletedWorkBlocks)")
                    .foregroundStyle(.white)
                Text("·")
                    .foregroundStyle(.white.opacity(0.3))
                Text(focusTotalString(pomodoro.todayFocusTime))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .fixedSize()
    }

    private var phaseTint: Color {
        pomodoro.runState == .paused ? .gray : pomodoro.phase.tint
    }

    private var isFinalStretch: Bool {
        pomodoro.isRunning && pomodoro.remaining <= 60
    }
}
