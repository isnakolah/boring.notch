//
//  CameraPane.swift
//  boringNotch
//

import AVFoundation
import Defaults
import SwiftUI

/// The mirror and the visualizer: the two things the notch draws that are not
/// information.
struct CameraPane: View {
    @Default(.showMirror) private var showMirror
    @Default(.mirrorShape) private var mirrorShape
    @Default(.showNotHumanFace) private var showNotHumanFace
    @Default(.useMusicVisualizer) private var useMusicVisualizer
    @Default(.customVisualizers) private var customVisualizers
    @Default(.selectedVisualizer) private var selectedVisualizer

    @State private var selectedListVisualizer: CustomVisualizer? = nil
    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0

    var body: some View {
        SettingsPane(SettingsPage.camera) {
            SettingCard("Camera") {
                VStack(spacing: 12) {
                    SettingRow("Boring mirror",
                               detail: checkVideoInput() ? "Shows the front camera in the notch."
                                                         : "No camera found on this Mac.") {
                        Toggle("", isOn: $showMirror)
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(!checkVideoInput())
                    }
                    SettingRow("Mirror shape") {
                        Picker("", selection: $mirrorShape) {
                            Text("Circle").tag(MirrorShapeEnum.circle)
                            Text("Square").tag(MirrorShapeEnum.rectangle)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                    }
                    SettingRow("Face animation while idle") {
                        Toggle("", isOn: $showNotHumanFace).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            visualizerCard
        }
    }

    private var visualizerCard: some View {
        SettingCard(detail: "Lottie animations played in place of the spectrogram.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Custom visualizers").font(NotchType.cardTitle)
                    if !customVisualizers.isEmpty {
                        SettingBadge("\(customVisualizers.count)")
                    }
                    SettingBadge("Coming soon")
                    Spacer()
                }
                SettingRow("Use the built-in spectrogram") {
                    Toggle("", isOn: $useMusicVisualizer.animation())
                        .labelsHidden().toggleStyle(.switch).disabled(true)
                }
                if !useMusicVisualizer {
                    SettingRow("Selected animation",
                               detail: customVisualizers.isEmpty ? "Add one below to choose it." : nil) {
                        if customVisualizers.isEmpty {
                            Text("None").font(NotchType.rowDetail).foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $selectedVisualizer) {
                                ForEach(customVisualizers, id: \.self) { Text($0.name).tag($0) }
                            }
                            .labelsHidden().frame(width: 180)
                        }
                    }
                }
                legacyVisualizerList
            }
        }
    }

    /// The Lottie list, add sheet and its action bar, kept as they were.
    private var legacyVisualizerList: some View {
        Form {
            Section {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(
                                url: visualizer.url, speed: visualizer.speed,
                                loopMode: .loop
                            )
                            .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Text("selected")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer != nil
                                ? selectedListVisualizer == visualizer
                                    ? Color.effectiveAccent : Color.clear : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedListVisualizer == visualizer {
                                selectedListVisualizer = nil
                                return
                            }
                            selectedListVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(
                    EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
                )
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""
                            url = ""
                            speed = 1.0
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if selectedListVisualizer != nil {
                                let visualizer = selectedListVisualizer!
                                selectedListVisualizer = nil
                                customVisualizers.remove(
                                    at: customVisualizers.firstIndex(of: visualizer)!)
                                if visualizer == selectedVisualizer && customVisualizers.count > 0 {
                                    selectedVisualizer = customVisualizers[0]
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("No custom visualizer")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) {
                    VStack(alignment: .leading) {
                        Text("Add new visualizer")
                            .font(.largeTitle.bold())
                            .padding(.vertical)
                        TextField("Name", text: $name)
                        TextField("Lottie JSON URL", text: $url)
                        NotchSlider(value: Binding(get: { Double(speed) },
                                                   set: { speed = CGFloat($0) }),
                                    range: 0...2,
                                    step: 0.1,
                                    label: "Speed",
                                    format: { String(format: "%.1f×", $0) },
                                    ends: ("Still", "2×"))
                            .padding(.vertical)
                        HStack {
                            Button {
                                isPresented.toggle()
                            } label: {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }

                            Button {
                                let visualizer: CustomVisualizer = .init(
                                    UUID: UUID(),
                                    name: name,
                                    url: URL(string: url)!,
                                    speed: speed
                                )

                                if !customVisualizers.contains(visualizer) {
                                    customVisualizers.append(visualizer)
                                }

                                isPresented.toggle()
                            } label: {
                                Text("Add")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .controlSize(.extraLarge)
                    .padding()
                }
            }
        }
        .formStyle(.columns)
        .frame(minHeight: 170)
    }

    private func checkVideoInput() -> Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}
