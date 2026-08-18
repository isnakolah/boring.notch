//
//  AccentPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// The one colour the app spends.
///
/// It was a card at the top of Advanced, which is where a setting goes when
/// nobody has decided where it belongs. It is not advanced — it is the most
/// visible choice in the window, and everything else in the design system is
/// deliberately achromatic so that this one lands.
struct AccentPane: View {
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData

    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil

    // macOS accent colors
    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"
        
        var id: String { self.rawValue }
        
        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }
    
    var body: some View {
        SettingsPane(SettingsPage.accent) {
            SettingCard("Accent colour",
                        detail: "The one colour Boring uses for anything active. Everything else stays neutral.") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $useCustomAccentColor) {
                        Text("System").tag(false)
                        Text("Custom").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 200)

                    if !useCustomAccentColor {
                        HStack(spacing: 12) {
                            AccentCircleButton(isSelected: true, color: .accentColor, isSystemDefault: true) {}
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Following macOS").font(NotchType.rowTitle)
                                Text("Changes with your system accent colour.")
                                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(
                                        isSelected: selectedPresetColor == preset,
                                        color: preset.color,
                                        isMulticolor: false
                                    ) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                        forceUiUpdate()
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            SettingRow("Or pick any colour") {
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                        forceUiUpdate()
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle().fill(customAccentColor).frame(width: 28, height: 28)
                                        if selectedPresetColor == nil {
                                            Circle().strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 28, height: 28)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .onAppear { initializeAccentColorState() }
            }
        }
        .onAppear { loadCustomColor() }
    }

    private func forceUiUpdate() {
        // Force refresh the UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }
    
    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }
    
    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            
            // Check if loaded color matches a preset
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }
    
    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        
        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }
    
    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil // Multicolor is selected when useCustomAccentColor is false
        } else {
            loadCustomColor()
        }
    }
}
