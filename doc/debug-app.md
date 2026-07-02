# Debug an app

## The debug loop is Simulator-first

Debug mode (JIT, hot reload) exists **only on the watchOS Simulator** — the
Dart JIT VM cannot run on a physical watch (see
[architecture.md](architecture.md)). The recommended loop:

1. Iterate on the Simulator in debug mode with hot reload.
2. Periodically verify on a physical watch with `--profile` (AOT, real
   performance, DevTools still attachable).
3. Ship `--release`.

## Running with hot reload

```sh
flutter-watchos devices
flutter-watchos run -d <simulator-id>
```

Terminal keys: `r` hot reload, `R` hot restart, `q` quit. The VM Service URI
printed at startup works with Dart DevTools and the IDE debuggers.

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
- **Simulator renders but is slow** — the watch renders on the CPU by
  design; profile on a physical watch before optimizing, the Simulator's
  software-rendering performance is not representative.
