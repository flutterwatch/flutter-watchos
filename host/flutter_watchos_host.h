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

// Flutter has drawn its first frame. Invoked once, on the main thread.
typedef void (*FlutterWatchOSFirstFrameCallback)(void* context);

// EXPERIMENTAL. A rendered frame as the engine's Metal render target itself
// (an `id<MTLTexture>` as an opaque pointer — this SDK declares no Metal), for
// a host that samples it on the GPU instead of showing a CGImage. Valid until
// `lease` is passed to FlutterWatchOSHostReleaseFrameTexture, which is also
// what lets the engine draw into that target again. Delivered on a GPU
// completion thread. The registration and release entry points —
//   void FlutterWatchOSHostSetTextureFrameCallback(
//       FlutterWatchOSTextureFrameCallback callback, void* context);
//   void FlutterWatchOSHostReleaseFrameTexture(void* lease);
// — are deliberately NOT declared here: the host resolves them with dlsym so
// it still links against an engine that predates them (see
// FlutterRunner.presentsTextures).
typedef void (*FlutterWatchOSTextureFrameCallback)(void* context,
                                                   void* texture,
                                                   void* lease);

// ---------------------------------------------------------------------------
// Composited frames. The engine places platform views from the layer tree
// (its own view embedder, the iOS shape): each frame is an ordered list of
// layers, bottom first — Flutter content rendered into an image, or a native
// view the host places at the geometry the layer tree gave it. A frame
// without platform views is one Flutter layer, and costs what it did before
// platform views existed.
// ---------------------------------------------------------------------------

typedef enum {
  kFlutterWatchOSLayerFlutter = 0,       // `image` and `region`
  kFlutterWatchOSLayerPlatformView = 1,  // `view_id` and the geometry
} FlutterWatchOSLayerType;

// One layer, in logical points (SwiftUI's), origin top-left of the screen.
typedef struct {
  FlutterWatchOSLayerType type;
  // Flutter: the rendered content, full-screen, BORROWED (+0, released by the
  // engine after the callback returns) — retain it to keep it, and keep only
  // the newest frame's: on Metal each image wraps one of the engine's render
  // targets without copying, and releasing it is what lets the engine draw
  // there again. NULL for a platform view.
  CGImageRef image;
  // Flutter: where the image carries pixels, as x, y, width, height quads;
  // everything outside is transparent. A layer with `region_count` 0 painted
  // nothing. Valid during the callback only.
  const double* region;
  int32_t region_count;
  // Platform view: which one (FlutterWatchOSPlatformViewGetType/GetParams
  // resolve it), and where. `x`..`height` are its bounds after every
  // transform the layer tree applied; `opacity` is the product of the
  // Opacity widgets above it; when `has_clip`, show only the part inside
  // `clip_*`, with corners of `clip_radius` when that is above zero.
  int64_t view_id;
  double x;
  double y;
  double width;
  double height;
  double opacity;
  bool has_clip;
  double clip_x;
  double clip_y;
  double clip_width;
  double clip_height;
  double clip_radius;
} FlutterWatchOSLayer;

// A composited frame, delivered on an engine-managed thread like the frame
// callback (a GPU completion thread on Metal; the raster thread for
// software). `layers` is valid during the callback only.
typedef void (*FlutterWatchOSLayersCallback)(void* context,
                                             const FlutterWatchOSLayer* layers,
                                             int32_t count);

// EXPERIMENTAL. The texture twin of FlutterWatchOSLayersCallback, for a host
// that samples render targets on the GPU: the same layer list, with the bottom
// Flutter layer's `image` NULL and its render target in `textures[0]` instead
// (an `id<MTLTexture>`, an sRGB view, as an opaque pointer). Every other entry
// of `textures` is NULL: Flutter layers above a platform view keep their
// `image`, borrowed as in the layers callback, because they need transparency.
// Frames with platform views come this way too. The `lease` keeps the texture
// valid until the host passes it to FlutterWatchOSHostReleaseFrameTextures,
// which is also what lets the engine draw into that target again, so hold at
// most the two most recent frames. `layers` and `textures` are valid during
// the callback only; the lease outlives it. Delivered on a GPU completion thread. Only the Metal
// renderer produces these; the software fallback keeps using the layers
// callback, and a host must accept both.
typedef void (*FlutterWatchOSTextureLayersCallback)(void* context,
                                                    const FlutterWatchOSLayer* layers,
                                                    void* const* textures,
                                                    int32_t count,
                                                    void* lease);

// Its registration and release entry points are not declared here either:
//   void FlutterWatchOSHostSetTextureLayersCallback(
//       FlutterWatchOSTextureLayersCallback callback, void* context);
//   void FlutterWatchOSHostReleaseFrameTextures(void* lease);
// (see FlutterRunner.presentsTextureLayers).

// Registration is deliberately NOT declared here either — the host resolves
//   void FlutterWatchOSHostSetLayersCallback(FlutterWatchOSLayersCallback, void*);
//   int64_t FlutterWatchOSHostHitTest(double x_points, double y_points);
// with dlsym (see FlutterRunner.compositesLayers) so it still links against an
// engine that predates composited frames, and falls back to the image callback
// plus the platform-view slot rects below.

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

// Report the watch's safe area in logical points — SwiftUI's `safeAreaInsets`
// verbatim. Reaches `MediaQuery.padding`, so it is what `SafeArea` insets by.
// Must be measured outside `.ignoresSafeArea()` and outside a ScrollView;
// both report zeros. Callable before or after Run.
void FlutterWatchOSHostSetSafeAreaInsets(double top_points,
                                         double right_points,
                                         double bottom_points,
                                         double left_points);

// Register the detent-haptic callback (the engine cannot play WatchKit
// haptics; the host does, in one line).
void FlutterWatchOSCrownSetTickCallback(FlutterWatchOSCrownTickCallback callback,
                                        void* context);

// Forward one raw Digital Crown sample (the change in SwiftUI's
// crown-rotation binding since the previous sample).
void FlutterWatchOSCrownDelta(double delta);

// Register a one-shot callback for the moment Flutter has RASTERISED its first
// frame. Registering after that has already happened invokes the callback
// immediately rather than never. Call on the main thread; the callback arrives
// there too.
//
// NOT the cue for taking down a launch placeholder, despite being added for
// one. Rasterisation precedes presentation: the pixels reach the host's SwiftUI
// view a display tick or more after this fires, so a placeholder dismissed here
// fades out over an empty surface and the content pops in behind it. Wait for
// the frame callback above instead — both renderers produce CGImages today,
// Metal included (Impeller reads its texture back through a shared buffer and
// presents through that same callback). The host module does exactly that; see
// FlutterRunner.displayingFlutterUI.
void FlutterWatchOSHostSetFirstFrameCallback(
    FlutterWatchOSFirstFrameCallback callback,
    void* context);

// One display refresh. The host calls this from a display-synced tick
// (SwiftUI's `TimelineView(.animation)` — watchOS has no CADisplayLink) and
// the engine renders a frame if it asked for one. A call with nothing pending
// is a no-op, so calling it every refresh is both correct and cheap.
//
// MUST be on the main thread (the one that called FlutterWatchOSHostRun).
// Without it the engine falls back to a free-running 60 Hz timer whose phase
// is unrelated to the display, which is judder even with the frame budget half
// empty.
void FlutterWatchOSHostNotifyVsync(void);

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
