#ifndef RUNNER_BRIDGE_H_
#define RUNNER_BRIDGE_H_

#include <stdbool.h>
#include <stdint.h>

#include <CoreGraphics/CoreGraphics.h>

#include "flutter_embedder.h"

// -----------------------------------------------------------------------------
// Engine-level watchOS host runtime (exported C ABI from
// libflutter_engine.dylib).
//
// ALL runtime logic lives INSIDE the engine: bootstrap (renderer, Dart
// snapshots, window metrics, semantics), the frame->CGImage pipeline, touch
// mapping, the complete Digital Crown scroll model (including the
// package:flutter_watchos raw-crown handoff, which the engine resolves via
// dlsym itself), and the text-input subsystem. The Swift host is generic glue:
// it displays frames, forwards gesture points and raw crown deltas, plays the
// detent haptic when the engine asks, and renders the invisible text-field
// overlay from the rects the engine publishes. These symbols are always
// present because the host links the engine, so they are declared (not
// dlsym'd) here.
// -----------------------------------------------------------------------------

// A rendered frame, delivered on the engine's raster thread. The CGImageRef is
// BORROWED (+0, released by the engine after the callback returns): Swift/ARC
// retains it automatically when the callback captures it; hop to the main
// thread to publish it.
typedef void (*FlutterWatchOSFrameCallback)(void* context, CGImageRef frame);

// The engine asks for one detent click (already distance- and rate-limited).
typedef void (*FlutterWatchOSCrownTickCallback)(void* context);

// Boot and run the Flutter engine for the app bundle. Idempotent; returns
// false if the engine failed to start. Call on the main thread.
bool FlutterWatchOSHostRun(const char* bundle_path,
                           double width_points,
                           double height_points,
                           double pixel_ratio,
                           FlutterWatchOSFrameCallback frame_callback,
                           void* frame_context);

// One touch sample in logical points; the engine tracks down/move/up phases.
void FlutterWatchOSHostTouch(double x_points, double y_points, bool ended);

// Register the detent-haptic callback (the engine cannot play WatchKit
// haptics; the host does, in one line).
void FlutterWatchOSCrownSetTickCallback(FlutterWatchOSCrownTickCallback callback,
                                        void* context);

// Forward one raw Digital Crown sample (the change in SwiftUI's
// crown-rotation binding since the previous sample).
void FlutterWatchOSCrownDelta(double delta);

// -----------------------------------------------------------------------------
// Engine-level watchOS text input. The host renders an invisible native proxy
// per published rect and forwards focus/edits; every protocol decision is the
// engine's.
// -----------------------------------------------------------------------------
typedef struct {
  int32_t node_id;
  double x;       // origin x in logical points
  double y;       // origin y in logical points
  double width;   // points
  double height;  // points
  bool obscured;  // render a SecureField when true
} FlutterWatchOSProxyField;

typedef void (*FlutterWatchOSChangeCallback)(void* context);

int32_t FlutterWatchOSTextInputCopyFields(FlutterWatchOSProxyField* out,
                                          int32_t max);
uint64_t FlutterWatchOSTextInputGeneration(void);
void FlutterWatchOSTextInputSetChangeCallback(
    FlutterWatchOSChangeCallback callback,
    void* context);
const char* FlutterWatchOSTextInputGetText(int32_t node_id);
void FlutterWatchOSTextInputBeginEditing(int32_t node_id);
void FlutterWatchOSTextInputSetText(int32_t node_id, const char* utf8);
void FlutterWatchOSTextInputSubmitEditing(void);
void FlutterWatchOSTextInputEndEditing(void);

#endif  // RUNNER_BRIDGE_H_
