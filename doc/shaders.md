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
