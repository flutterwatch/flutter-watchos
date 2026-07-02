#ifndef RUNNER_BRIDGE_H_
#define RUNNER_BRIDGE_H_

#include <stdbool.h>
#include <stdint.h>
#include "flutter_embedder.h"

// The raw Digital Crown bridge (flutter_watchos_crown_mode /
// flutter_watchos_crown_push_delta) is provided by the flutter_watchos package
// and resolved at runtime via dlsym in FlutterRunner (see sendCrownDelta). It
// is intentionally NOT declared here, so an app that doesn't link the package
// still builds.

// -----------------------------------------------------------------------------
// Engine-level watchOS text input (exported C ABI from libflutter_engine.dylib).
//
// All text-input logic — semantics→rect math, per-field state, the
// flutter/textinput protocol, obscureText, focus — lives INSIDE the engine
// (shell/platform/embedder/watchos/). The host only renders a generic overlay of
// invisible native fields from the rects the engine publishes and feeds typed
// text back; it owns none of the logic. These symbols are always present because
// the host links the engine, so they are declared (not dlsym'd) here.
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

void FlutterWatchOSTextInputSetPixelRatio(double pixel_ratio);
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
