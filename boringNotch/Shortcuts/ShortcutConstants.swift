//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    static let pomodoroStartPause = Self("pomodoroStartPause", default: .init(.t, modifiers: [.command, .shift]))
    static let pomodoroSkipPhase = Self("pomodoroSkipPhase")
    static let pomodoroStopTimer = Self("pomodoroStopTimer")
    static let copilotToggleCall = Self("copilotToggleCall", default: .init(.c, modifiers: [.option, .command]))
    static let copilotToggleLayout = Self("copilotToggleLayout", default: .init(.t, modifiers: [.option, .command]))
    static let copilotDismiss = Self("copilotDismiss", default: .init(.period, modifiers: [.option, .command]))
}
