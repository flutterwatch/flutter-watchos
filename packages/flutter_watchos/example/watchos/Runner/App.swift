import SwiftUI

@main
struct FlutterWatchosExampleApp: App {
    var body: some Scene {
        WindowGroup {
            #if arch(arm64_32)
            // 32-bit watches (Series 4–8 / SE) are not supported.
            UnsupportedDeviceView()
            #else
            FlutterHostView()
            #endif
        }
    }
}

// Shown on 32-bit watches (Series 4–8 / SE), which this app does not support.
struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Flutter Watchos Example")
                .font(.headline)
            Text("Requires Apple Watch Series 9 or later.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#if !arch(arm64_32)
struct FlutterHostView: View {
    @ObservedObject var runner = FlutterRunner.shared
    // The engine publishes the text-field rects; this is a pure mirror of them.
    @ObservedObject var textInput = WatchTextInput.shared
    @State private var crownValue: Double = 0.0
    @FocusState private var isFocused: Bool
    // Which text-field proxy (by semantics node id) currently holds focus.
    @FocusState private var focusedField: Int32?

    var body: some View {
        GeometryReader { _ in
            Group {
                if let frame = runner.frame {
                    Image(decorative: frame, scale: runner.pixelRatio)
                        .resizable()
                        .frame(width: runner.sizePoints.width, height: runner.sizePoints.height)
                } else {
                    Text("Starting Flutter…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { runner.touch(at: $0.location, ended: false) }
                    .onEnded { value in
                        runner.touch(at: value.location, ended: true)
                        // If this gesture fired, the tap landed OUTSIDE every proxy
                        // field (a proxy consumes in-field taps). For a tap (small
                        // drag distance), drop focus: clear SwiftUI focus AND tell
                        // the engine to unfocus. The watchOS keyboard often clears
                        // `focusedField` itself when it closes, leaving the Flutter
                        // field still focused with nothing to clear it; the explicit
                        // `endEditing()` (idempotent) covers that. Scrolls/pans
                        // (large translation) leave focus alone.
                        let dragDistance = hypot(value.translation.width,
                                                 value.translation.height)
                        if dragDistance < 8 {
                            focusedField = nil
                            textInput.endEditing()
                        }
                    }
            )
            .focusable()
            .focused($isFocused)
            .digitalCrownRotation(
                $crownValue,
                from: -10000.0,
                through: 10000.0,
                by: 0.05,
                sensitivity: .high,
                isContinuous: true,
                // MUST stay false with this fine `by:` step. The system crown
                // haptic fires once per `by:` detent; at by:0.05 a fast frame
                // crosses ~hundreds of detents, so the Taptic Engine backs up and
                // stutters the (software-rendered) scroll on real hardware. The
                // detent click is produced by the Runner instead, rate-limited so
                // it can't flood (see crownHapticTickPoints in FlutterRunner).
                isHapticFeedbackEnabled: false
            )
            .onChange(of: crownValue) { oldValue, newValue in
                runner.sendCrownDelta(newValue - oldValue)
            }
            // Text entry. We keep an INVISIBLE native proxy over EVERY Flutter
            // text field, positioned from the rect list the ENGINE publishes
            // (`textInput.fields`). Because the proxy is present from the start,
            // the user's first tap lands on a real native field → the system
            // keyboard opens immediately (masked for `obscured` fields). The proxy
            // is bound to the engine's live value, so editing is pre-filled in
            // place. This overlay is purely declarative — all logic is in the
            // engine; the host renders fields and forwards focus/edits.
            .overlay {
                ForEach(textInput.fields) { field in
                    // Each proxy binds to the engine's isolated per-node value
                    // (keyed by the field's Semantics Node ID), so two fields can't
                    // mix data. SecureField for obscured fields, TextField otherwise.
                    let textBinding = Binding(
                        get: { textInput.text(for: field.id) },
                        set: { textInput.setText($0, for: field.id) }
                    )
                    proxy(isObscured: field.isObscured, text: textBinding)
                        .focused($focusedField, equals: field.id)
                        .submitLabel(.done)
                        // Keyboard Done. IMPORTANT: @FocusState never fires on
                        // watchOS, so `focusedField` is nil here and the
                        // onChange path below never runs — the submit must be
                        // sent to the engine directly. (The nil-set stays for a
                        // future watchOS where FocusState works; endEditing
                        // after submitEditing is a no-op.)
                        .onSubmit {
                            textInput.submitEditing()
                            focusedField = nil
                        }
                        // Make the proxy effectively invisible while keeping it
                        // tappable AND keyboard-raising. watchOS will NOT present the
                        // keyboard for a field it considers hidden — `.opacity(0)`,
                        // `.hidden()`, `.mask`, `.colorMultiply` all focus the field
                        // but suppress the keyboard. A *near-zero* opacity (0.02) is
                        // still "visible" to the system (keyboard works) yet renders
                        // the faint system fill at 2% — invisible in practice over the
                        // Flutter field. `.foregroundStyle/.tint(.clear)` additionally
                        // clear the text + cursor. `contentShape` keeps the full rect
                        // tappable regardless of opacity (opacity doesn't affect hit
                        // testing).
                        .textFieldStyle(.plain)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .opacity(0.02)
                        // The frame must match the engine's field rect exactly, or
                        // the native tap area would be larger than the visible
                        // Flutter field.
                        .frame(width: field.rect.width, height: field.rect.height)
                        .contentShape(Rectangle())
                        .position(x: field.rect.midX, y: field.rect.midY)
                }
            }
            .onChange(of: focusedField) { _, newValue in
                if let id = newValue {
                    textInput.beginEditing(id)
                } else {
                    textInput.endEditing()
                }
            }
        }
        .ignoresSafeArea()
        // System time visibility. Default: VISIBLE (the watchOS HIG
        // expectation). Apps opt into hiding it from Dart via
        // `WatchStatusBar.hidden = true` (package:flutter_watchos) — e.g. for
        // games or full-bleed UIs; there is no system API to reposition the
        // clock, so a custom placement means hiding it and drawing your own.
        .modifier(SystemTimeHidden(hidden: runner.statusBarHidden))
        .onAppear {
            FlutterRunner.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    /// The native input control for a field — SecureField (masked) when obscured,
    /// otherwise a plain TextField — bound to that field's engine-owned state.
    @ViewBuilder
    private func proxy(isObscured: Bool, text: Binding<String>) -> some View {
        if isObscured {
            SecureField("", text: text)
        } else {
            TextField("", text: text)
        }
    }
}

/// Hides the system status bar (the clock) only when the app asked for it.
/// watchOS has no public API for this; `_statusBarHidden()` is SwiftUI SPI,
/// so it is applied ONLY on explicit opt-in (`WatchStatusBar.hidden = true`)
/// — the default path never touches it and keeps the time visible.
private struct SystemTimeHidden: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        if hidden {
            content._statusBarHidden()
        } else {
            content
        }
    }
}
#endif  // arch(arm64_32)
