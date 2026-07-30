# Debug an app

## The debug loop is Simulator-first

Debug mode (JIT, hot reload) exists **only on the watchOS Simulator** — the
Dart JIT VM cannot run on a physical watch (see
[architecture.md](architecture.md)). The recommended loop:

1. Iterate on the Simulator in debug mode with hot reload.
2. Periodically verify on a physical watch with `--profile` (AOT, real
   performance, live DevTools — see
   [Profiling on a physical watch](#profiling-on-a-physical-watch)).
3. Ship `--release`.

## Running with hot reload

```sh
flutter-watchos devices
flutter-watchos run -d <simulator-id>
```

Terminal keys: `r` hot reload, `R` hot restart, `q` quit. The VM Service URI
printed at startup works with Dart DevTools and the IDE debuggers.

## Profiling on a physical watch

`run --profile` on a real watch gives you a live Dart VM Service, so DevTools
and the IDE debuggers attach exactly as they do on any other device:

```sh
flutter-watchos run --profile -d <watch-id>
```

The DevTools link is printed at startup. No flag, no setup — profile runs on a
watch bring up the connection automatically.

**Both devices must be on the same network as this Mac.** A watch has no
network path of its own; it reaches your Mac through its paired iPhone. So the
iPhone needs to be nearby, unlocked, and on the same Wi-Fi as the Mac — a Mac
on ethernet or USB tethering while the phone is on Wi-Fi will not work. If the
app cannot reach back, `run` says so, and distinguishes "the VM Service never
started" from "it started but the app could not reach this Mac".

The watch must also stay **awake and unlocked** for the whole session. When the
display times out, watchOS suspends the app and the connection drops — you will
see `Lost connection to device` roughly half a minute in, with nothing wrong on
either side. Two things make a session survivable:

- Settings → Display & Brightness → **Wake Duration → 70 Seconds**.
- Keep it on the charger, which stops it sleeping while you work in DevTools.

To tell this apart from a real failure, check whether frames were still being
produced when the connection dropped. If the app went quiet at the same moment,
the watch slept; if it kept rendering, the transport failed.

What works, measured on an Apple Watch Series 10 (watchOS 26.5):

- **Live DevTools** — attaches, inspects isolates, evaluates expressions.
- **The Flutter Frames chart** — the framework's `Flutter.Frame` events reach
  DevTools with per-frame build, raster and vsync-overhead timings. Measured at
  a sustained 59.4 frames/second on a Series 10.
- **Timeline / Performance** — the full frame pipeline is instrumented:
  `Animator::BeginFrame`, `BUILD`/`LAYOUT`/`PAINT`/`COMPOSITING`,
  `Rasterizer::*`, `LayerTree::Preroll`. An 8-second capture of an animating
  app yielded ~30,000 events.
- **`FrameTiming`** — `SchedulerBinding.addTimingsCallback` reports real build
  and raster times in-process, and is the lightest way to measure a specific
  interaction.

Current limits:

- **Connection setup sometimes fails — expect to retry.** In testing, two
  launches in five never brought the connection up: the app reported the VM
  Service closing, and every reconnect then failed outright. That last part is
  by design and is why it cannot be recovered in place — once DDS has taken
  control the VM Service stops listening, so one lost connection ends the
  session. Quit and re-run. Once a session is established it is stable
  (measured: 94 seconds and 2.9 MB uninterrupted). Under `-v` a healthy tunnel
  logs `vm bridge connection N: first write ok` then `first read ok`.
- **The CPU profiler is empty.** `getCpuSamples` returns a populated function
  table but zero samples, so DevTools' CPU Profiler page has nothing to draw.
  The Dart sampling profiler needs Mach thread APIs the watchOS device SDK
  removes — the same reason there is no JIT on device. Use the timeline to find
  *where* time goes; it cannot tell you which Dart functions are hot.
- **The link is slow, so bulk views take time.** The watch compresses what it
  sends, which buys roughly 5x on live traffic and 10x on bulk timeline data —
  the wire runs at its ceiling of ~65 KB/s while carrying 580–700 KB/s of
  payload. DevTools connects in about 20 seconds even against an app rendering
  at 60fps (before compression that case never connected at all).

  The Performance page is still the expensive one, because it fetches the whole
  timeline and a 60fps app produces an enormous amount of it. If you only need
  build and raster times for a specific interaction, `FrameTiming`
  (`SchedulerBinding.addTimingsCallback`) runs in-process and costs nothing on
  the wire.
- **Hot reload is Simulator-only** (AOT on device, as above).

## Attaching

If the app is already running (or was launched outside `run`):

```sh
flutter-watchos attach --debug-url <vm-service-uri>
```

The URI is printed at engine startup and appears in the device console logs.

## Logs

```sh
flutter-watchos logs -d <device-id>
```

For the Simulator you can also use `xcrun simctl spawn <udid> log stream`
filtered on your bundle id; `print()`/`debugPrint()` output lands there.

## Physical-watch quirks

Installs and launches go through `devicectl` to the **paired** watch, which
is tunnelled via the iPhone. This path is occasionally flaky:

- **CoreDeviceError 4000 / RemotePairingError 1001** — the tunnel dropped.
  Usually fixed by: watch unlocked and on its charger, iPhone unlocked and
  nearby, both on the same Wi-Fi; then retry. Stubborn cases: toggle
  Developer Mode on the watch (Settings → Privacy & Security) or reboot
  watch + iPhone.
- **First install per team** needs the certificate trusted on the watch:
  Settings → General → Device Management.
- The CLI retries transient tunnel failures automatically; `-v` shows the
  underlying `devicectl` invocations if you need to see what's happening.

## Common issues

- **"Debug mode is not supported on a physical Apple Watch"** — expected;
  use `--simulator` for debug or `--profile`/`--release` for the device.
- **Engine artifacts missing / download fails** — run `flutter-watchos
  login` first ([accounts.md](accounts.md)), then `flutter-watchos precache`.
- **Keyboard doesn't appear when tapping a TextField** — make sure you're on
  the latest engine (`flutter-watchos upgrade`); text entry is engine-side
  and needs no app code.
- **Simulator renders but is slow** — Simulator performance is not
  representative of a real Apple Watch; profile on a physical watch before
  optimizing.
