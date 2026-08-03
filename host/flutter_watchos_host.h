#ifndef FLUTTER_WATCHOS_HOST_H_
#define FLUTTER_WATCHOS_HOST_H_

#include <stdbool.h>
#include <stdint.h>

#include <CoreGraphics/CoreGraphics.h>

// -----------------------------------------------------------------------------
// watchOS host runtime — the C entry points the FlutterWatchOS host module
// links against. The host is generic glue: it displays frames, forwards
// gesture points and raw crown deltas, plays the detent haptic on request,
// and renders the text-field overlay. These symbols are always present in the
// engine, so they are declared (not dlsym'd) here.
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

// -----------------------------------------------------------------------------
// watchOS platform views. The engine publishes a rect (in logical points) for
// every WatchPlatformView widget; the host overlays the native SwiftUI view
// registered for its viewType (see WatchPlatformViewRegistry in
// FlutterRunner.swift). Same mirror contract as the text input above.
// -----------------------------------------------------------------------------
typedef struct {
  int64_t view_id;
  double x;       // origin x in logical points
  double y;       // origin y in logical points
  double width;   // points
  double height;  // points
  bool visible;   // false: keep the native view alive but hidden
} FlutterWatchOSPlatformViewSlot;

typedef void (*FlutterWatchOSPlatformViewsChangeCallback)(void* context);

int32_t FlutterWatchOSPlatformViewsCopy(FlutterWatchOSPlatformViewSlot* out,
                                        int32_t max);
uint64_t FlutterWatchOSPlatformViewsGeneration(void);
void FlutterWatchOSPlatformViewsSetChangeCallback(
    FlutterWatchOSPlatformViewsChangeCallback callback,
    void* context);
// Owned by the engine, valid until the next Get* call from the same thread.
const char* FlutterWatchOSPlatformViewGetType(int64_t view_id);
const char* FlutterWatchOSPlatformViewGetParams(int64_t view_id);
// True: composite the view UNDER the frame image (the widget punches a
// transparent hole for it); false: classic overlay above the frame.
bool FlutterWatchOSPlatformViewGetBelowFrame(int64_t view_id);

// -----------------------------------------------------------------------------
// watchOS accessibility (the VoiceOver bridge). The engine turns the semantics
// tree into a flat list of elements — rect in logical points, label/value/hint,
// traits, the actions the node offers — and the host places an invisible
// SwiftUI view per element carrying the accessibility modifiers (see
// WatchAccessibility in WatchAccessibility.swift). Same mirror contract as the
// two overlays above.
// -----------------------------------------------------------------------------

// Traits of an element; the host maps them onto SwiftUI AccessibilityTraits.
enum {
  kFlutterWatchOSA11yTraitButton = 1 << 0,
  kFlutterWatchOSA11yTraitHeader = 1 << 1,
  kFlutterWatchOSA11yTraitLink = 1 << 2,
  kFlutterWatchOSA11yTraitImage = 1 << 3,
  kFlutterWatchOSA11yTraitSelected = 1 << 4,
  kFlutterWatchOSA11yTraitStaticText = 1 << 5,
  kFlutterWatchOSA11yTraitUpdatesFrequently = 1 << 6,
  kFlutterWatchOSA11yTraitNotEnabled = 1 << 7,
  kFlutterWatchOSA11yTraitAdjustable = 1 << 8,
  kFlutterWatchOSA11yTraitTextField = 1 << 9,
  kFlutterWatchOSA11yTraitToggle = 1 << 10,
  kFlutterWatchOSA11yTraitKeyboardKey = 1 << 11,
};

// Actions an element offers; the values are flutter::SemanticsAction bits,
// which is also what PerformAction takes back.
enum {
  kFlutterWatchOSA11yActionTap = 1 << 0,
  kFlutterWatchOSA11yActionLongPress = 1 << 1,
  kFlutterWatchOSA11yActionScrollLeft = 1 << 2,
  kFlutterWatchOSA11yActionScrollRight = 1 << 3,
  kFlutterWatchOSA11yActionScrollUp = 1 << 4,
  kFlutterWatchOSA11yActionScrollDown = 1 << 5,
  kFlutterWatchOSA11yActionIncrease = 1 << 6,
  kFlutterWatchOSA11yActionDecrease = 1 << 7,
  kFlutterWatchOSA11yActionDismiss = 1 << 18,
  kFlutterWatchOSA11yActionExpand = 1 << 24,
  kFlutterWatchOSA11yActionCollapse = 1 << 25,
};

typedef struct {
  int32_t node_id;
  double x;       // origin x in logical points
  double y;       // origin y in logical points
  double width;   // points
  double height;  // points
  uint32_t traits;
  int32_t actions;
  int32_t custom_action_count;
  double sort_priority;  // descending = VoiceOver reading order
  // Moves only when the element's strings change; the host caches them and
  // re-reads only when it does (rects move every frame while scrolling).
  uint64_t content_version;
  bool hidden;           // scrolled out; focusing scrolls it into view
  bool enabled;          // false: the host disables the element
} FlutterWatchOSA11yElement;

typedef void (*FlutterWatchOSA11yChangeCallback)(void* context);

int32_t FlutterWatchOSA11yCopyElements(FlutterWatchOSA11yElement* out,
                                       int32_t max);
uint64_t FlutterWatchOSA11yGeneration(void);
void FlutterWatchOSA11ySetChangeCallback(
    FlutterWatchOSA11yChangeCallback callback,
    void* context);
// Owned by the engine, valid until the next Get* call from the same thread.
const char* FlutterWatchOSA11yGetLabel(int32_t node_id);
const char* FlutterWatchOSA11yGetValue(int32_t node_id);
const char* FlutterWatchOSA11yGetHint(int32_t node_id);
const char* FlutterWatchOSA11yGetIdentifier(int32_t node_id);
const char* FlutterWatchOSA11yGetCustomActionLabel(int32_t node_id,
                                                   int32_t index);
// The engine detects VoiceOver itself (WKAccessibility notifications); this is
// the override a host or a test uses to report a reader WatchKit cannot see.
void FlutterWatchOSA11ySetScreenReaderRunning(bool running);
void FlutterWatchOSA11yFocusGained(int32_t node_id);
void FlutterWatchOSA11yFocusLost(int32_t node_id);
bool FlutterWatchOSA11yPerformAction(int32_t node_id, int32_t action);
bool FlutterWatchOSA11yPerformCustomAction(int32_t node_id, int32_t index);

#endif  // FLUTTER_WATCHOS_HOST_H_
