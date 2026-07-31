# Measuring performance on a watch

Performance questions on watchOS have to be settled on hardware, and hardware
fights back: the display dims a few seconds after your wrist drops, and the
frame rate collapses with it. A run that ignores that produces numbers blended
from two different machines.

[`tool/benchmarks/frame_bench.dart`](../tool/benchmarks/frame_bench.dart) is a
drop-in probe that handles it. Copy it into your app's `lib/` and call
`installFrameBench()` from `main()`:

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installFrameBench();
  runApp(const MyApp());
}
```

Then run in profile on a real watch and read the log:

```sh
flutter-watchos run --profile -d <watch-id>
```

```
BENCH window 7  n=120  fps=60.0 duty=0.61 OK  build p50=0.42 p90=0.50  raster p50=9.69 p90=11.61
BENCH TOTAL windows=7 n=840  build p50=0.44 p90=0.52 p99=0.99  raster p50=9.66 p90=11.96 p99=13.50
```

`BENCH TOTAL` pools every frame from healthy windows only, so a run just has to
catch a few seconds of real rendering — it does not have to be clean end to
end.

## Read `duty` before you read the milliseconds

`duty` is build + raster over the actual frame interval: **what fraction of each
frame was spent doing work.**

| duty | meaning |
|---|---|
| ~0.3 | comfortable — most of the frame is idle |
| ~0.6 | working, still inside budget |
| **~1.0** | **saturated — the frame is full and you are dropping frames** |

A saturated app can still report a plausible-looking frame rate. One measured
case sat at 56.5fps with duty 1.01: not obviously broken, but every frame
completely full, and any extra work would drop frames. `duty` says that where
`fps` alone does not.

## Why windows are marked OK or DEGRADED

A window is kept if **either** the frame rate is healthy **or** the work
accounts for the interval:

```dart
final bool healthy = fps >= kHealthyFps || duty >= kHealthyDuty;
```

Both halves matter, and each one alone is wrong:

- **Frame rate alone** discards every window of a genuinely slow app. A
  shader-heavy screen running at 13fps with ~78ms of work per frame is a real,
  saturated measurement — exactly the case you are trying to study — but it
  looks like a dimmed display to a rate-only test.
- **Duty alone** discards every window of a fast app. Something comfortably
  inside its budget is idle most of the frame by definition, so a duty-only
  test throws away healthy 60fps windows as "degraded".

What is actually being excluded is a window that is *slow and idle*: ~1fps with
a few milliseconds of work in it. That is the display dimmed, and it says
nothing about the change under test.

## Keeping the screen lit

There is no public API that keeps a watch at full frame rate with the wrist
down — `WKExtendedRuntimeSession` keeps your app from being *suspended*, but
the display still dims and the rate still collapses. Practical options:

- Rotate the Digital Crown or tap the screen during the run. Note crown input
  is forwarded as gestures and carries a little cost of its own, so keep it
  consistent across the runs you intend to compare.
- Settings → Display & Brightness → **Wake Duration → 70 Seconds**, and keep
  the watch on its charger.
- Or just run for longer and let the gate do the work: dimmed windows are
  discarded and healthy ones pooled, so a 5-minute run accumulates clean frames
  across however many times the screen happens to light up.

## Do not measure over a live DevTools connection

The VM Service tunnel to a watch compresses and long-polls on the same small
CPU your frames are using. Streaming a timeline while measuring inflates the
thing you are measuring. Run the probe, then read the log — the numbers are
aggregated in-process precisely so nothing has to leave the device.

## A Simulator number is not a device number

Measured against an Apple Watch Series 10, on the same code:

| | Simulator | Series 10 |
|---|---|---|
| raster p50, shader-heavy screen | 4.89 ms | **17.4 ms** |
| frame rate | 60.3 fps | **56.4 fps** |
| duty | 0.32 | **1.01** |

The Simulator runs this work about **3–4x faster** than the watch, because it
is a Mac. On the app above it reported two thirds of the frame idle while the
watch was completely saturated and dropping frames — it would have called an
over-budget app healthy.

What does carry across is the **ratio** between two options. In the same
comparison a change that cut raster to 0.553 of baseline on the watch measured
0.476 on the Simulator: close enough to rank two implementations, not close
enough to tell you whether either fits a frame.

So: use the Simulator to compare A against B, and hardware to decide whether A
is fast enough. Never let the Simulator tell you which part of the frame to
optimise.

## `build` versus `raster`

- **`build`** is your Dart — widget builds, layout, paint recording.
- **`raster`** is turning that into pixels. Custom painting, shaders, blurs,
  large images and heavy compositing land here.

Both are reported at p50/p90/p99 because the tail is what users feel: an effect
that averages comfortably but spikes past budget reads as intermittent jank,
and a p50 alone hides it.
