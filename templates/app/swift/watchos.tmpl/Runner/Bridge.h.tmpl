#ifndef RUNNER_BRIDGE_H_
#define RUNNER_BRIDGE_H_

#include <stdbool.h>
#include <stdint.h>

#include <CoreGraphics/CoreGraphics.h>

#include "flutter_embedder.h"

// -----------------------------------------------------------------------------
// watchOS host runtime — the C entry points the Swift runner links against.
// The runner is generic glue: it displays frames, forwards gesture points and
// raw crown deltas, plays the detent haptic on request, and renders the
// text-field overlay. These symbols are always present, so they are declared
// (not dlsym'd) here.
// -----------------------------------------------------------------------------

// A rendered frame. Swift/ARC retains the CGImageRef when the callback captures
// it; hop to the main thread to publish it.
typedef void (*FlutterWatchOSFrameCallback)(void* context, CGImageRef frame);

// Request for one detent click.
typedef void (*FlutterWatchOSCrownTickCallback)(void* context);

// Boot and run the Flutter engine for the app bundle. Idempotent; returns
// false if the engine failed to start. Call on the main thread.
bool FlutterWatchOSHostRun(const char* bundle_path,
                           double width_points,
                           double height_points,
                           double pixel_ratio,
                           FlutterWatchOSFrameCallback frame_callback,
                           void* frame_context);

// Forward one touch sample in logical points. `ended` marks the final sample.
void FlutterWatchOSHostTouch(double x_points, double y_points, bool ended);

// Register the detent-haptic callback (the engine cannot play WatchKit
// haptics; the host does, in one line).
void FlutterWatchOSCrownSetTickCallback(FlutterWatchOSCrownTickCallback callback,
                                        void* context);

// Forward one raw Digital Crown sample (the change in SwiftUI's
// crown-rotation binding since the previous sample).
void FlutterWatchOSCrownDelta(double delta);

// -----------------------------------------------------------------------------
// watchOS text input. The host overlays a native field for each editable rect
// and forwards focus and edits (see WatchTextInput in FlutterRunner.swift).
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
