# Fragment shaders

Flutter's fragment shaders work on watchOS. You author them the same way you
would on any other platform — a `.frag` file listed in `pubspec.yaml`, loaded
with `ui.FragmentProgram.fromAsset` — and they run on a real Apple Watch.

```yaml
flutter:
  shaders:
    - shaders/plasma.frag
```

```dart
final ui.FragmentProgram program =
    await ui.FragmentProgram.fromAsset('shaders/plasma.frag');

final ui.FragmentShader shader = program.fragmentShader()
  ..setFloat(0, size.width)
  ..setFloat(1, size.height)
  ..setFloat(2, timeSeconds);

canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
```

Nothing here is watch-specific. If you have a shader that runs on iOS, it will
compile and run on the watch too.

## Why this is worth knowing

watchOS gives native developers very little to work with here:

| Native route | watchOS |
|---|---|
| Metal / MetalKit | framework not present in the watchOS SDK |
| SwiftUI `.colorEffect` / `.layerEffect` / `.distortionEffect` | not available |
| Core Image | framework not present |
| SpriteKit `SKShader` | available (watchOS 2.0+) |

So a native watch app *can* run a custom shader, but only as `SKShader` inside
a SpriteKit scene — a separate rendering world from the SwiftUI interface it
would have to sit next to. There is no supported way to apply a shader to a
SwiftUI view. In Flutter the shader is just another paint operation, so it
composes with the rest of your widget tree like it does everywhere else.

## Budget for them

This is the part to take seriously. Shader work is **expensive on watch
hardware** relative to a phone — enough that a single full-screen effect can
consume most of a 60fps frame budget on its own. Shaders are usable, not free.

Practical consequences:

- **Shade the smallest area you can.** Cost scales with the number of pixels
  the shader covers, so a shader behind a small card is cheap and the same
  shader behind the whole screen may not fit the budget.
- **One at a time.** Two full-screen effects composited together is usually
  over budget even when each is fine alone.
- **Measure on a real watch, in profile.** Debug builds and the Simulator will
  not tell you whether an effect fits.

## Measure with FrameTiming, not a frame counter

A ticker- or `FPS`-style counter is actively misleading for shader work. It
runs on the UI thread and reports the rate the UI thread kept up with, which
can look like a healthy 60fps while the frame is in fact over budget — the
shader's cost shows up in **`rasterDuration`**, not in build time.

```dart
SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
  for (final FrameTiming t in timings) {
    // The number that matters for a shader. Compare against ~16.6ms at 60fps.
    print(t.rasterDuration.inMicroseconds / 1000);
  }
});
```

Watch the mean and the peak, not just the mean: an effect that averages
comfortably but spikes past the budget will read as intermittent jank.

## Two changes that bought a real app 60fps

Both come from a game whose animated border shader was essentially the whole
frame — with the effect switched off, raster fell from 17.7ms to 3.2ms. On an
Apple Watch Series 10 it could not hold the frame rate: **56.5fps with the
frame fully saturated**. After both changes it holds **60.0fps with 39% of the
frame idle**.

### Compute per-frame values in Dart, not per pixel

A shader body runs once for every pixel it covers. Anything in it that depends
only on uniforms is the same value for all of them, so it is being recomputed
thousands of times a frame for one answer. Transcendentals are worth hunting
first:

```glsl
// Before — a sin per pixel, for a value that changes once per frame.
uniform float uTime;
float breathe = 0.85 + 0.15 * sin(uTime * 2.2);
```

```dart
// After — a sin per frame, in the painter.
final double breathe = 0.85 + 0.15 * math.sin(t * 2.2);
shader.setFloat(6, breathe);
```

Anything derived purely from state — a colour that depends on a game variable,
`time * rate` phases, a `max()` of two uniforms — moves the same way. In the
app above this was worth about 9% of the shader's cost on its own. On a GPU it
would be close to free; here it is not.

### Shade at reduced resolution through an offscreen

Rasterise the effect into a `ui.Picture`, turn that into an image at a smaller
size than the area it will fill, and let the blit scale it up:

```dart
@override
void paint(Canvas canvas, Size size) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas offscreen = Canvas(recorder);
  paintEffect(offscreen, size);            // your existing shader painting
  final ui.Picture picture = recorder.endRecording();
  // toImageSync takes PIXELS while Size is logical, so this shades at half
  // resolution on a 2x screen. That is the point — and the cost.
  final ui.Image image =
      picture.toImageSync(size.width.ceil(), size.height.ceil());
  picture.dispose();
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, size.width, size.height),
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.low,
  );
  image.dispose();
}
```

This was the larger half of the win, and it is **a quality trade, not a free
structural change**: fewer pixels get shaded and the result is scaled up, so
the effect is softer. Soft glows tolerate it well; sharp-edged effects and
anything with fine high-frequency detail will not. Judge it on a watch, at
full size — a simulator screenshot comes back at logical resolution and cannot
show a 2x upscale.

Two results worth knowing before you tune the size:

- Shading at 0.5, 0.7, 0.85 and 1.0 of logical size all cost the same, so
  there is no reason to go below 1.0 and blur it further.
- Passing a size in *device* pixels — i.e. actually shading at full
  resolution — was **much worse than not doing this at all**, so the technique
  only pays while it is also downscaling.

Sanity-check any result here against frames per second rather than
`rasterDuration` alone. In the full-resolution case above, frames were 72ms
apart with only 11ms of build and raster reported in them; a large part of the
cost of this path does not show up in `FrameTiming` at all.

## Two mistakes that cost more than the shader

Both of these show up as "the shader is slow" when it isn't:

- **Recompiling the program.** `FragmentProgram.fromAsset` compiles the
  shader. Calling it in `build()` — or on every navigation — produces a stall
  on the first frame after each push. Load once and cache the
  `FragmentProgram` for the life of the process; creating a `FragmentShader`
  from a cached program per frame is fine.
- **A bare `Ticker` for animation time.** A raw `Ticker` keeps firing while
  its page is covered by another route, so an off-screen shader carries on
  burning CPU and battery — which a watch has little of. Drive animation from
  an `AnimationController` with `vsync: this`, whose ticker `TickerMode` mutes
  automatically when the page is not visible.

Decoded images fed into a shader deserve the same treatment: decode once and
cache, rather than re-decoding per navigation.

## Build modes

Judge performance in **profile** on a physical watch. Note that release
engines are not part of the closed beta by default (see
[Accounts & engine artifacts](accounts.md)), so profile is the mode to
benchmark in unless your account has release access.
