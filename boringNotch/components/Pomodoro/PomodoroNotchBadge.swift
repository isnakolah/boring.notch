//
//  PomodoroNotchBadge.swift
//  boringNotch
//
//  Closed-notch surface for a running session: phase icon wrapped in a
//  draining progress ring on the left of the physical notch, clock countdown
//  on the right. Takes over the slot the CLAUDE/CODEX usage badges
//  occupy, and hands it back the moment the session ends.
//

import SwiftUI

struct PomodoroNotchBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called on hover — opens the notch on the Pomodoro tab, mirroring the
    /// usage badges' behaviour.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var pomodoro = PomodoroManager.shared

    /// Both sides get the same width so the black spacer stays centred on the
    /// physical notch. Without this the wider countdown drags the layout left
    /// and slides under the notch itself.
    /// Accommodates the widest clock (`1:00:00`) without moving either side
    /// when a session crosses an hour boundary.
    private let sideWidth: CGFloat = 74

    /// The last minute of a work block gets a red, slightly urgent readout.
    private var isFinalStretch: Bool {
        pomodoro.isRunning && pomodoro.remaining <= 60
    }

    private var tint: Color {
        if pomodoro.runState == .paused { return .gray }
        return isFinalStretch ? .red : pomodoro.phase.tint
    }

    var body: some View {
        HStack(spacing: 0) {
            phaseIcon
                .frame(width: sideWidth, alignment: .trailing)
                .padding(.trailing, 10)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            readout
                .frame(width: sideWidth, alignment: .leading)
                .padding(.leading, 10)
        }
        // Hug the content so the black pill ends where the timer does, instead
        // of stretching to the window's full width. Same trick as the usage badges.
        .fixedSize()
        .frame(height: height, alignment: .center)
        // A paused session should read as "not running" from the corner of the
        // eye, before the icon is ever parsed.
        .opacity(pomodoro.runState == .paused ? 0.45 : 1)
        .animation(.smooth(duration: 0.2), value: pomodoro.runState)
        .onHover { hovering in
            if hovering { onBadgeHover?() }
        }
    }

    private var phaseIcon: some View {
        Image(systemName: pomodoro.statusIcon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect)
    }

    private var readout: some View {
        Text(notchClockString(pomodoro.remaining))
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(isFinalStretch ? .red : .white)
        .fixedSize()
        .animation(.smooth(duration: 0.25), value: pomodoro.remaining)
    }
}
