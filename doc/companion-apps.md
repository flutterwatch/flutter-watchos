# Companion apps

A **companion** app is an iPhone app and an Apple Watch app that ship together
as one App Store submission and talk to each other. This page covers the three
things that are specific to building one with `flutter-watchos`: how the mode is
decided, how to structure the shared Dart, and how the two apps communicate.

For the submission mechanics see [publish-app.md](publish-app.md); for the
wiring `host` reconciles see [commands.md](commands.md#host).

## The mode comes from the project shape

There is no setting. A project with an `ios/` Flutter app is a companion
project; one without is standalone (watch-only). `create`, `build` and `run`
all re-derive it, and `flutter-watchos host` reports it:

```sh
flutter create --platforms=ios .      # this project is now a companion
flutter-watchos host                  # confirms it, and heals the wiring
```

In companion mode the iOS Runner gets an "Embed Prebuilt watchOS App" build
phase and the watch `Info.plist` declares `WKCompanionAppBundleIdentifier`.
Build the watch app first; the iOS build picks it up:

```sh
flutter-watchos build watchos --release --target lib/main_watch.dart
flutter build ipa
```

## Structuring the shared code

Put the model, business logic and transport policy in a `lib/core/` that
imports no UI and branches on no platform, and give each device its own widget
tree and its own entrypoint:

```
lib/
  main.dart          → phone/
  main_watch.dart    → watch/
  core/                          shared verbatim
```

Two entrypoints rather than one `main.dart` branching at runtime: a runtime
branch compiles *both* UIs into *both* binaries, and there is no reason for a
watch binary to carry a phone UI. Select with `--target`:

```sh
flutter run                                                    # phone
flutter-watchos run -d <watch-id> --target lib/main_watch.dart # watch
```

Inside `core/`, where behaviour really does differ per device, branch on
`FlutterWatchosPlatform.isWatch`. **Not** `Platform.isIOS`, which is `true` on
watchOS as well — see [plugins.md](plugins.md).

Lay the two UIs out separately — the watch wants whole-row tap targets, haptic
confirmation, Digital Crown scrolling and as little text entry as possible, and
reusing the phone's layout produces an app that is bad on both.

But share the **design system**, in a third directory both UIs import. Two
screens that nobody ever sees side by side drift: one picks a seed colour
"tuned" for black, the other paints the same status a different green, and the
two stop looking like one product. Put the seed, the semantic colours (a
`ThemeExtension` is the right home), the text ramp, the tile/row widgets, and
the status→colour/icon/wording mapping in one place; derive the watch theme from
the phone's by scaling type, so the two colour schemes are equal rather than
merely similar.

Worth deciding early: **watchOS has no light mode.** If the phone app follows the
system appearance, the two devices can never share an actual colour value — only
a hue. Committing the phone to the same dark appearance is what makes "the same
green" literally true; if you need light mode on the phone, accept that parity
is per-brightness and define both variants centrally.

Keep raw `Color(0x…)` and `fontSize:` out of both UI layers. A test that greps
for them is worth writing, because this is a rule discipline alone does not
hold.

## Talking to the other device

WatchConnectivity is the only transport Apple provides, and it needs native
code on both sides. One FFI implementation covers both: the phone and the watch
compile the same source, and inbound payloads are pushed into Dart from the
delegate queue rather than polled.
[`flutter_watch_link`](https://github.com/flutterwatch/plugins/tree/main/packages/flutter_watch_link)
provides both behind one Dart API.

Its three transports are not interchangeable:

- `sendMessage` — immediate, and only while the counterpart app is running.
  Queues nothing otherwise.
- `updateApplicationContext` — one latest-wins snapshot. What a device that was
  switched off reads to catch up in a single delivery.
- `transferUserInfo` — FIFO queue that survives the counterpart being closed.

Most apps want all three: the live tier for responsiveness, the snapshot as a
self-healing repair path, and the queue for durability. Because a payload can
then arrive twice by different routes, **make the receiving side idempotent**
rather than trying to deduplicate — an order-independent merge is far less
work than reconstructing delivery order.

## Testing on the Simulator

WatchConnectivity works between paired Simulators, but the pairing is not set up
for you:

```sh
xcrun simctl pair <watch-udid> <phone-udid>
xcrun simctl list pairs        # wait for "(active, connected)"
```

Boot both, and **launch the iPhone app before the watch app** — the watch
reports its counterpart as installed only once the phone app exists, and until
then every send fails with "Companion app is not installed". A watch app
side-loaded onto a simulator that has never had the phone app installed will not
connect at all.

**`reachable` is asymmetric**, which catches people out when they try to test
the queue. The phone reports the watch reachable only while the watch app is
actually running. The watch reports the phone reachable whether or not the
phone app is running, because WatchConnectivity is entitled to launch the iOS
app in the background to deliver a `sendMessage`. Two consequences:

- Killing the phone app does not make the watch queue anything — it keeps
  choosing the live tier. To exercise `transferUserInfo`, stop the *watch* app
  and send from the phone.
- A watch-side `sendMessage` can be accepted and still not reach a phone app
  that is not running — on the Simulator, ours did not; the phone converged
  from the snapshot on next launch instead. This is exactly what the debounced
  snapshot is for, and it is why a send that returned successfully is not
  evidence of delivery.
