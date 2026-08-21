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

**The paired iPhone must be able to reach this Mac.** A watch has no network
path of its own; its traffic arrives at your Mac *from* the phone, so the phone
is the one hop that has to find you. It needs to be nearby and unlocked, and on
a network that routes here. Two layouts work:

- **Same Wi-Fi** — the simple case, and the one to reach for first.
- **Personal Hotspot over USB** — plug the phone in and turn the hotspot on.
  The Mac lands on the phone's `172.20.10.0/28` subnet, which the phone can
  obviously reach, so no Wi-Fi is needed at all. `run` prefers that address
  over any other, precisely because a Mac that is tethered *and* on wired
  ethernet has several addresses and the phone can only route to one.

A Mac on wired ethernet alone will not work, however close the phone is: it has
no route into that subnet.

If the app cannot reach back, `run` says so, distinguishes "the VM Service
never started" from "it started but the app could not reach this Mac", and
names the address the watch was told to dial. When that address is the wrong
one of several — a layout the ordering above cannot infer — override it:

```sh
FLUTTER_WATCHOS_RELAY_HOST=192.168.1.24 flutter-watchos run --profile -d <watch-id>
```

Because the watch dials your Mac by LAN address, the relay has to accept
connections from the network rather than loopback. Each run mints a secret
token and serves only under it, so nothing else on the network can read or
write the debug session; the token lives only in memory and in the launched
app's environment. Nothing is exposed after `run` exits.

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

**None of this reaches a release build.** The bridge is compiled only for debug
and profile — a release binary contains a no-op stub and links no networking
code for it — and a release app is never launched with VM Service flags. So
`--release` and your App Store archive are byte-for-byte unaffected by anything
on this page.

Current limits:

- **Connection setup sometimes fails.** Roughly half of launches report the VM
  Service closing, after which every reconnect fails outright — once DDS takes
  control the VM Service stops listening, so one lost connection ends the
  session and it cannot be recovered in place. Re-running usually works.

  To avoid it entirely, disable DDS and attach DevTools yourself:

  ```sh
  flutter-watchos run --profile --no-dds -d <watch-id>
  ```

  then point a standalone DevTools at the VM Service URI that prints:

  ```sh
  dart devtools http://127.0.0.1:<port>/
  ```

  Once established, a session is stable either way. Under `-v` a healthy
  tunnel logs `vm bridge connection N: first write ok` then `first read ok`.
- **The CPU profiler is empty.** `getCpuSamples` returns a populated function
  table but zero samples, so DevTools' CPU Profiler page has nothing to draw.
  The Dart sampling profiler needs Mach thread APIs the watchOS device SDK
  removes — the same reason there is no JIT on device. Use the timeline to find
  *where* time goes; it cannot tell you which Dart functions are hot.
- **The link is slow, so bulk views take a moment.** The watch compresses what
  it sends (~5x live, ~9–10x on bulk timeline data) and keeps several transfers
  in flight to hide the phone-proxied path's round-trip time; together the
  tunnel carries 800–900 KB/s of payload over a ~90 KB/s wire. In practice:
  DevTools connects in ~20 seconds, and the Performance page — the most
  expensive view — loads in about a minute against an app rendering at 60fps,
  then stays live, frames chart included. (Before this, that app never managed
  to connect at all.) For a quick number without DevTools, `FrameTiming`
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

### Logs from a physical watch

A watch has no console to attach to, and `print()` and engine logs both go to
stderr, which on a device goes nowhere. Launch with `--watchos-log-to-file` and
they are written into the app's own container instead:

```sh
xcrun devicectl device process launch --device <udid> --terminate-existing \
    <bundle-id> --watchos-log-to-file
```

Then pull the file:

```sh
xcrun devicectl device copy from --device <udid> \
    --domain-type appDataContainer --domain-identifier <bundle-id> \
    --source Documents/engine.log --destination ./engine.log
```

The file is truncated at every launch, so it always describes the run you just
made rather than an older one. It is strictly opt-in: without the flag nothing
is written and nothing is redirected, which keeps crashes going to the system
log where the crash reporter can see them.

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
