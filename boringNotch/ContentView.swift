//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var pomodoro = PomodoroManager.shared
    @ObservedObject var copilotSession = CopilotLiveSession.shared
    /// Through the wrapper, not `Defaults[...]` inline: a bare subscript read
    /// inside a computed property registers no dependency, so the slider moved and
    /// the panel never redrew.
    @Default(.callaCopilotGlassLevel) private var copilotGlassLevel
    @State private var hoverTask: Task<Void, Never>?
    @State private var pomodoroAutoCloseTask: Task<Void, Never>?
    @State private var lessonAutoCloseTask: Task<Void, Never>?
    @State private var copilotAutoCloseTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    /// The live copilot panel reads as glass; every other state is the opaque
    /// slab the notch has always been.
    private var isCopilotGlass: Bool {
        vm.notchState == .open && coordinator.currentView == .copilot
            // The sign-in panel takes the copilot's place, so it takes its glass
            // too — otherwise signing in drops back to the opaque slab mid-flow.
            // A starting call takes the glass too: it becomes the live panel a
            // second later, and swapping the background underneath the reader at
            // that moment is a flash for nothing.
            && (copilotSession.isLive || copilotSession.starting || copilotSession.signInActive)
    }

    @ViewBuilder
    private var notchBackground: some View {
        if isCopilotGlass {
            ZStack {
                // `.regularMaterial`, not `.ultraThinMaterial`: the thinnest material
                // lets whatever is behind the notch — a bright browser, a white
                // document — sit directly under the text, and no amount of white
                // text survives that. The frost is what makes the panel a surface
                // rather than a window.
                Rectangle().fill(.regularMaterial)
                // Frost stays dark enough for readable white text even over a
                // bright share. The slider still controls how much desktop comes
                // through, but never turns material into an almost-black scrim.
                Color.black.opacity(0.68 - (0.28 * copilotGlassLevel))
            }
        } else {
            Color.black
        }
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if copilotSession.isLive && vm.notchState == .closed && !vm.hideOnClosed {
            // Room for the activity glyph and the call clock.
            chinWidth += 150
        } else if pomodoro.isActive && vm.notchState == .closed && !vm.hideOnClosed {
            // Room for the phase ring and the "20m 15s" countdown.
            chinWidth += 150
        } else if Defaults[.showUsageBesideNotch] && vm.notchState == .closed && !vm.hideOnClosed {
            // Room for a "CLAUDE 23/38" badge on each side of the notch.
            chinWidth += 150
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    // Pin the open content to the full open height instead of
                    // letting it size to whatever the current tab needs —
                    // otherwise the notch changes height as you switch tabs.
                    // The 12 accounts for the bottom padding applied below.
                    .frame(
                        height: vm.notchState == .open ? max(0, vm.notchSize.height - 12) : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        // The live call panel buys its width back. Every other
                        // state keeps the corner inset, which is what stops a
                        // tab's content from running into the shape's curve —
                        // but this one is dense text on a fixed slab, and the
                        // usual inset plus the 12 below spent about 130pt of a
                        // 600pt panel on margins.
                        ? (isCopilotGlass
                           ? 10
                           : Defaults[.cornerRadiusScaling]
                           ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom))
                        : cornerRadiusInsets.closed.bottom
                    )
                    // Horizontal and bottom are set apart now: the height above
                    // is computed against a bottom inset of 12, so only the
                    // horizontal one may vary by state.
                    .padding(.horizontal, vm.notchState == .open ? (isCopilotGlass ? 4 : 12) : 0)
                    .padding(.bottom, vm.notchState == .open ? 12 : 0)
                    .background(notchBackground)
                    .clipShape(currentNotchShape)
                    .overlay {
                        // Only the glass panel needs an edge; the opaque slab
                        // reads as one piece with the display bezel already.
                        if isCopilotGlass {
                            currentNotchShape
                                .stroke(.white.opacity(0.08), lineWidth: 0.5)
                        }
                    }
                    .overlay(alignment: .top) {
                        // Stays opaque even behind glass: this hairline is what
                        // fuses the panel with the physical notch, and a
                        // translucent version of it reads as a seam.
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    // Width is pinned as tightly as height. The panel is built
                    // at the widest any mode needs, so without this every tab
                    // would stretch to the copilot's width — the notch is only
                    // allowed to grow for a live call, and goes straight back
                    // afterwards.
                    .frame(
                        width: vm.notchState == .open ? vm.notchSize.width : nil,
                        height: vm.notchState == .open ? vm.notchSize.height : nil,
                        alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    // Live text must retain full contrast when pointer leaves.
                    .opacity(1)
                    .contentShape(currentNotchShape)
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
            // This stack is the whole of what the panel paints — the notch plus
            // its chin — so its frame is exactly the region that should take
            // clicks. Everything else in the window is transparent and must
            // fall through.
            .background(InteractiveRegionReporter())
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        // Move dragDetector here, but we will fix dragDetector definition instead.
        .background(dragDetector, alignment: .top)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    // This fires the moment a drag enters, ahead of every other
                    // drop path, and it used to hard-code the Shelf. That is why
                    // the choice was never seen: by the time the chooser had an
                    // opinion, the Shelf was already on screen and the answer had
                    // been given for you.
                    if NotchDropRouter.shared.isSplitAvailable {
                        NotchDropRouter.shared.beginChoosing()
                        coordinator.currentView = .dropChooser
                    } else {
                        coordinator.currentView = .shelf
                    }
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                // A choice is on screen and unanswered. Moving the pointer onto
                // one of its halves hands the drag to that half's own delegate,
                // which reads as the outer target being exited — so this timer
                // starts while the reader is still deciding, and the notch shuts
                // under the pointer half a second later.
                if NotchDropRouter.shared.ownsCurrentView { return }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if copilotSession.isLive && vm.notchState == .closed && !vm.hideOnClosed {
                          // A live call takes this slot from the timer and the usage
                          // badges: a Pomodoro can wait, a conversation cannot.
                          CopilotNotchBadge(
                              notchWidth: vm.closedNotchSize.width - 20,
                              height: vm.effectiveClosedNotchHeight,
                              onBadgeHover: {
                                  coordinator.currentView = .copilot
                                  doOpen()
                              }
                          )
                          .transition(.opacity)
                      } else if pomodoro.isActive && vm.notchState == .closed && !vm.hideOnClosed {
                          // A live session owns this slot; the usage badges come
                          // back the moment it ends.
                          PomodoroNotchBadge(
                              notchWidth: vm.closedNotchSize.width - 20,
                              height: vm.effectiveClosedNotchHeight,
                              onBadgeHover: {
                                  coordinator.currentView = .pomodoro
                                  doOpen()
                              }
                          )
                          .transition(.opacity)
                      } else if Defaults[.showUsageBesideNotch] && vm.notchState == .closed && !vm.hideOnClosed {
                          UsageNotchBadges(
                              notchWidth: vm.closedNotchSize.width - 20,
                              height: vm.effectiveClosedNotchHeight,
                              onBadgeHover: {
                                  // Hovering a side badge opens straight to the usage
                                  // tab; hovering the center notch keeps normal flow.
                                  coordinator.currentView = .usage
                                  doOpen()
                              }
                          )
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open && !isCopilotGlass {
                           // A live call takes the whole slab, tab row included.
                           // Mid-call there is nothing to switch to — the panel
                           // is the only thing worth the space, and its own
                           // header already carries the state and the controls.
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else if vm.notchState == .open {
                           // The live call's status and controls occupy the band
                           // either side of the camera housing, which is dead
                           // space now that the tab row is gone.
                           CallaCopilotLiveHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .dropChooser:
                        NotchDropChooserView(
                            // `dropEvent` is what tells the close debounce that
                            // the drag ended in something. Without it, dropping
                            // on a half opened the right view and the notch shut
                            // half a second later, which reads as nothing having
                            // happened at all.
                            onShelf: { providers in
                                vm.dropEvent = true
                                coordinator.currentView = .shelf
                                acceptIntoShelf(providers)
                                NotchDropRouter.shared.endDelivering()
                            },
                            onMeeting: { providers in
                                vm.dropEvent = true
                                routeToKnowledge(providers)
                            },
                            onSpringLoad: { side in
                                vm.dropEvent = true
                                NotchDropRouter.shared.beginDelivering()
                                NotchDropRouter.shared.finish()
                                switch side {
                                case .shelf:
                                    coordinator.currentView = .shelf
                                case .meeting:
                                    coordinator.currentView = .knowledgeDrop
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                        vm.open(size: knowledgeNotchSize)
                                    }
                                }
                                NotchDropRouter.shared.endDelivering()
                            })
                    case .knowledgeDrop:
                        CallaKnowledgeDropView()
                    case .shelf:
                        ShelfView()
                    case .tutor:
                        CallaTabView()
                    case .copilot:
                        // The live panel replaces the tab outright for the
                        // length of a call — mid-call there is nothing to
                        // configure, only something to read.
                        if copilotSession.signInActive {
                            // Outranks the live panel: a call without credentials
                            // produces nothing, so the field to fix that is the
                            // only useful thing to show.
                            CallaCopilotSignInView()
                        } else if copilotSession.isLive {
                            CallaCopilotLiveView()
                        } else if copilotSession.starting || copilotSession.startupFailed {
                            // The seconds between pressing the button and the
                            // microphone opening — and, when it never opens, the
                            // same panel saying so. Previously this was the tab
                            // with its Start button still on it, which read as
                            // the press having been lost, whether the call was
                            // three seconds away or never coming.
                            CallaCopilotStartingView()
                        } else {
                            CallaCopilotTabView()
                        }
                    case .usage:
                        UsageMonitorView()
                    case .pomodoro:
                        PomodoroView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(
            of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
            delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting) { providers in
                // Root drop target covers closed notch. It must accept instead
                // of cancelling, otherwise it shadows the background detector.
                vm.dropEvent = true
                doOpen()
                // This path used to go straight to Shelf *and* start the
                // transfer, so a file dropped anywhere but the two dedicated
                // targets was sent to a phone without being asked. It is the
                // same question as everywhere else, so it gets the same answer.
                if NotchDropRouter.shared.isSplitAvailable {
                    routeDrop(providers)
                    return
                }
                coordinator.currentView = .shelf
                ShelfStateViewModel.shared.load(providers)
                Task { await ShelfShareService.shared.shareDroppedFiles(providers) }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .pomodoroPhaseEnded)) { _ in
            showPomodoroPhaseChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaLessonDidStart)) { _ in
            showLessonStart()
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaCopilotSuggestion)) { _ in
            showCopilotSuggestion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .callaKnowledgeWantsNotch)) { _ in
            // No explicit size: the surface itself knows whether it arrived from
            // a drop or from the calendar, and those want different heights.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                vm.open()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .copilotLiveDidChange)) { _ in
            syncCopilotLiveNotch()
        }
        // The size sliders in Settings, applied as they move rather than at the
        // next open.
        .onChange(of: copilotSession.panelSizeRevision) { _, _ in
            applyLivePanelSize()
        }
        .onChange(of: vm.notchState) { _, state in
            // Only an open notch may host a caret. Closing hands the keyboard
            // back to whatever the user was actually working in.
            BoringNotchSkyLightWindow.acceptsKeyFocus = state == .open
            if state == .closed {
                NSApp.deactivate()
            }
        }
    }

    /// A finished phase pops the notch open on the Pomodoro tab, then gets out
    /// of the way — a notch that stays open after every break is worse than no
    /// popup at all. Hovering keeps it up.
    private func showPomodoroPhaseChange() {
        coordinator.currentView = .pomodoro
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            vm.open()
        }

        pomodoroAutoCloseTask?.cancel()
        pomodoroAutoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !isHovering, vm.notchState == .open else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                vm.close()
            }
        }
    }

    /// A new pointer peeks the notch just long enough to read it.
    ///
    /// Shorter than a lesson start, because this fires mid-conversation: the
    /// user is about to speak, and a panel parked over the call is worse than
    /// no panel. Hovering holds it open for a longer read.
    private func showCopilotSuggestion() {
        guard Defaults[.callaCopilotEnabled], Defaults[.callaCopilotAutoReveal] else { return }
        // Never steal the notch from a live lesson.
        guard coordinator.currentView != .tutor || CallaEngineClient.shared.status.activeLesson?.active != true else { return }

        // A dismissed panel comes back for a fresh pointer — dismissing means
        // "not now", not "not for this call".
        copilotSession.repin()

        coordinator.currentView = .copilot
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            vm.open()
        }

        // A live call holds the notch itself; only the peek that fires outside
        // one gets taken away again.
        guard !copilotSession.pinsNotchOpen else {
            copilotAutoCloseTask?.cancel()
            return
        }

        copilotAutoCloseTask?.cancel()
        copilotAutoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !isHovering, vm.notchState == .open else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                vm.close()
            }
        }
    }

    /// Opens, resizes, or releases the notch when the live session changes.
    ///
    /// Both a call starting and a full/compact toggle land here, so the size
    /// change is animated the same way in either direction.
    private func syncCopilotLiveNotch() {
        copilotAutoCloseTask?.cancel()

        guard copilotSession.pinsNotchOpen else {
            // The call ended: hand the notch back rather than leaving a dead
            // panel parked over whatever comes next.
            guard !copilotSession.isLive, vm.notchState == .open,
                  coordinator.currentView == .copilot else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                if isHovering {
                    // The pointer is still on it — ending a call usually means
                    // having just clicked End call — so shrink back to the
                    // ordinary open size instead of closing under the cursor.
                    // Leaving it at the copilot's size would strand a notch
                    // twice as tall as anything that belongs in it.
                    coordinator.currentView = .home
                    vm.open(size: openNotchSize)
                } else {
                    vm.close()
                }
            }
            return
        }
        coordinator.currentView = .copilot
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            vm.open(size: copilotSession.preferredOpenSize)
        }
    }

    /// Resizes an already-open call panel while the size sliders move.
    ///
    /// Guarded on the panel actually being a call: a closed notch must not pop
    /// open because someone touched a slider, and another tab must not be
    /// resized to the call panel's dimensions.
    private func applyLivePanelSize() {
        guard vm.notchState == .open,
              coordinator.currentView == .copilot else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            vm.open(size: copilotSession.preferredOpenSize)
        }
    }

    /// A lesson start pins the notch to Tutor and shows the live lesson, then
    /// steps aside: the learner needs the app being taught, not a panel parked
    /// over it. The tab stays selected, so reopening lands back on the lesson.
    private func showLessonStart() {
        coordinator.currentView = .tutor
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            vm.open()
        }

        lessonAutoCloseTask?.cancel()
        lessonAutoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !isHovering, vm.notchState == .open else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                vm.close()
            }
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        // SwiftUI `onDrop` is unreliable in our non-activating transparent
        // panel while closed. Native AppKit drag registration owns that state.
        .overlay {
            NotchFileDropTarget(
                enabled: Defaults[.boringShelf],
                onEntered: {
                    // With the copilot on, a drop is ambiguous — Shelf-and-send or
                    // give it to a meeting — so the notch opens onto the choice
                    // rather than committing to one behind the user's back.
                    //
                    // Asked on an open notch as well as a closed one. The guard
                    // used to be `notchState == .closed`, which meant dragging
                    // onto a notch that happened to be open skipped the question
                    // entirely and sent the file.
                    guard !NotchDropRouter.shared.ownsCurrentView else { return }
                    if NotchDropRouter.shared.isSplitAvailable {
                        NotchDropRouter.shared.beginChoosing()
                        coordinator.currentView = .dropChooser
                    } else if vm.notchState == .closed {
                        coordinator.currentView = .shelf
                    }
                    doOpen()
                },
                onDrop: { providers in
                    vm.dropEvent = true
                    doOpen()
                    // Caught by the closed-notch target before either half saw it.
                    // Hold the files and leave the question up, rather than
                    // guessing — guessing is what made this confusing.
                    // A drop that outran the drag-enter — fast enough that the
                    // choice never got on screen. Start it now and hold the
                    // files, rather than answering it for them.
                    if NotchDropRouter.shared.isChoosing || NotchDropRouter.shared.isSplitAvailable {
                        routeDrop(providers)
                        return
                    }
                    coordinator.currentView = .shelf
                    acceptIntoShelf(providers)
                }
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    /// Tells the panel which of its points are real.
    ///
    /// Sits as a background, so it is laid out at exactly the size of the view
    /// it is measuring and re-reports on every frame of the open/close spring.
    /// AppKit rather than a `GeometryReader` because the answer has to be in
    /// window coordinates and the window is the thing that needs telling.
    private struct InteractiveRegionReporter: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { ReporterView() }
        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? ReporterView)?.report()
        }

        final class ReporterView: NSView {
            override func layout() {
                super.layout()
                report()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                report()
            }

            func report() {
                guard let panel = window as? BoringNotchSkyLightWindow else { return }
                panel.setInteractiveRect(convert(bounds, to: nil))
            }
        }
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(width: vm.closedNotchSize.width, height: vm.closedNotchSize.height)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            // A completed drop is authoritative. Open Shelf here rather than
            // relying on `isTargeted`, which becomes false before providers
            // finish loading and used to leave a closed notch behind.
            vm.dropEvent = true
            doOpen()
            if NotchDropRouter.shared.isSplitAvailable {
                routeDrop(providers)
                return true
            }
            coordinator.currentView = .shelf
            acceptIntoShelf(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    /// Sends a drop to the half it was released over.
    ///
    /// The chooser's own target is not the only thing that can catch a release:
    /// the notch's outer target and the AppKit one both sit under it, and
    /// whichever wins used to `hold` the files and ask the question a second
    /// time — with the answer already on screen, highlighted, under the
    /// pointer. If a side is lit, that *is* the answer.
    private func routeDrop(_ providers: [NSItemProvider]) {
        let router = NotchDropRouter.shared
        guard let side = router.hovering else {
            NotchDropRouter.log.info("routeDrop with no side — holding")
            router.beginChoosing()
            router.hold(providers)
            coordinator.currentView = .dropChooser
            return
        }

        NotchDropRouter.log.info("routeDrop \(String(describing: side), privacy: .public)")
        router.beginDelivering()
        router.finish()
        switch side {
        case .shelf:
            coordinator.currentView = .shelf
            acceptIntoShelf(providers)
            router.endDelivering()
        case .meeting:
            routeToKnowledge(providers)
        }
    }

    /// What dropping has always done: keep it, and send it on.
    ///
    /// Untouched on purpose. The transfer to a paired device is surprising if you
    /// did not expect it, which is exactly why it now only happens on the half
    /// that says so.
    private func acceptIntoShelf(_ providers: [NSItemProvider]) {
        ShelfStateViewModel.shared.load(providers)
        Task { await ShelfShareService.shared.shareDroppedFiles(providers) }
    }

    /// Hands the files to the copilot. Nothing is sent anywhere.
    private func routeToKnowledge(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            NotchDropRouter.log.info("routeToKnowledge with \(providers.count) provider(s)")
            let accepted = await CallaKnowledgeAttach.shared.accept(providers)
            NotchDropRouter.log.info("accept -> \(accepted)")
            // Asked for Remember, so show Remember. This used to fall through to
            // the Shelf when nothing readable was found, which meant every
            // failure — including one caused by a stale provider — looked like
            // the Shelf having been chosen, and the actual reason never surfaced.
            if !accepted {
                CallaKnowledgeAttach.shared.failure =
                    "Nothing here the copilot can read. PDFs, documents, text and images work."
            }
            coordinator.currentView = .knowledgeDrop
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                vm.open(size: knowledgeNotchSize)
            }
            NotchDropRouter.shared.endDelivering()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Void

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL, .url, .utf8PlainText, .plainText, .data])
        guard !providers.isEmpty else { return false }
        onDrop(providers)
        return true
    }
}

/// AppKit destination for Finder drags over the closed non-activating notch.
/// SwiftUI's drop bridge does not reliably receive those drags on this panel.
private struct NotchFileDropTarget: NSViewRepresentable {
    let enabled: Bool
    let onEntered: () -> Void
    let onDrop: ([NSItemProvider]) -> Void

    func makeNSView(context: Context) -> NativeNotchDropView {
        let view = NativeNotchDropView()
        view.update(enabled: enabled, onEntered: onEntered, onDrop: onDrop)
        return view
    }

    func updateNSView(_ view: NativeNotchDropView, context: Context) {
        view.update(enabled: enabled, onEntered: onEntered, onDrop: onDrop)
    }
}

private final class NativeNotchDropView: NSView {
    private var enabled = false
    private var onEntered: (() -> Void)?
    private var onDrop: (([NSItemProvider]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { nil }

    func update(enabled: Bool, onEntered: @escaping () -> Void, onDrop: @escaping ([NSItemProvider]) -> Void) {
        self.enabled = enabled
        self.onEntered = onEntered
        self.onDrop = onDrop
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled, !providers(from: sender.draggingPasteboard).isEmpty else { return [] }
        DispatchQueue.main.async { [onEntered] in onEntered?() }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        enabled && !providers(from: sender.draggingPasteboard).isEmpty ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        enabled && !providers(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let providers = providers(from: sender.draggingPasteboard)
        guard !providers.isEmpty else { return false }
        DispatchQueue.main.async { [onDrop] in onDrop?(providers) }
        return true
    }

    private func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return [NSItemProvider(object: string as NSString)]
        }
        return []
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
