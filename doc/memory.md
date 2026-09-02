# The 300 MB memory ceiling

watchOS gives an app a hard per-process memory limit and kills it the moment it
crosses. On a Series 10 that limit is **300 MB** — measured, not estimated:
`WatchMemory.footprint + WatchMemory.available` reads 300.0 MB at every point
in a run. The kill is a bare `SIGKILL` — no Dart exception, no crash dialog,
nothing in the run log except:

```
App terminated due to signal 9.
```

That silence is the hard part. A `signal 9` looks identical whether you ran out
of memory, the tunnel dropped, or the app was killed for something else, so the
first job is always to find out which.

## Confirm it was memory

Every jetsam kill writes a report **on the watch**. Pull it without Xcode:

```sh
xcrun devicectl device info files -d <watch-id> --domain-type systemCrashLogs
```

```sh
xcrun devicectl device copy from -d <watch-id> --domain-type systemCrashLogs \
  --source JetsamEvent-2026-08-27-012146.ips --destination ./jetsam.ips
```

The payload is JSON after the first line. What matters is the process list:

```
Runner   302.4 MB   reason = per-process-limit
```

`per-process-limit` means your app alone hit the ceiling — not that the watch
was short on memory. In the report above the device still had 15.7 MB free.

**watchOS does not write a report for every kill.** It logged one, then stayed
silent through the next five, then logged again. An absent report is not
evidence that a kill was not jetsam.

## Read the footprint, not `ProcessInfo.currentRss`

This is the trap that will cost you the most time. Dart's RSS ignores GPU
allocations; jetsam charges them to your process. Use
[`WatchMemory`](../packages/flutter_watchos/lib/src/memory.dart) instead — it
reports `phys_footprint`, the figure jetsam actually judges, and the bytes you
have left before the kill:

```dart
import 'package:flutter_watchos/flutter_watchos.dart';

debugPrint('${WatchMemory.footprint ~/ 1048576}MB used, '
    '${WatchMemory.available ~/ 1048576}MB left');
```

A probe that allocated GPU textures in 1.65 MB steps on a Series 10, printing
both figures at each step:

| GPU allocated | `currentRss` | `WatchMemory.footprint` | `WatchMemory.available` |
|---|---|---|---|
| 0 MB | 51 MB | 25.0 MB | 275.0 MB |
| 34 MB | 61 MB | 85.5 MB | 214.5 MB |
| 97 MB | 64 MB | 154.6 MB | 145.4 MB |
| 160 MB | 58 MB | 223.3 MB | 76.7 MB |
| 222 MB | 56 MB | 293.9 MB | 6.1 MB → `signal 9` |

RSS never left the 50s while the real footprint climbed to 294 MB. Note also
that `footprint + available` is 300.0 MB on every row: that is the limit,
confirmed from the device rather than assumed.

Two things worth taking from that table:

- **An empty app costs about 25 MB**, so roughly 275 MB is yours to spend.
- **GPU textures cost more than their pixel arithmetic** — 222 MB of nominal
  texture raised the footprint by 269 MB, about 21% over. Budget for the
  overhead.

`available` returns 0 on the Simulator, which has no jetsam limit to report
against; check `WatchMemory.availableIsSupported` to tell that apart from
genuinely having no room left. `footprint` is readable in both places, but on
the Simulator it does not track GPU allocations the way it does on a device.

## Where the memory actually goes in a 3D app

Three things dominate, in this order.

### 1. Shadow maps — check this first

`flutter_scene`'s `DirectionalLight` defaults are sized for a desktop:
`shadowCascadeCount: 4` and `shadowMapResolution: 1024` build a **4096x1024**
atlas. With a colour and a depth attachment, and the render graph keeping
`framesInFlight = 2` of each:

```
directional_shadow_map        4096x1024  r32Float         16.00 MB
directional_shadow_map_depth  4096x1024  d32FloatS8UInt   20.00 MB
                                          x2 in flight  =  72.00 MB
```

**72 MB — about a quarter of the entire budget, for shadows on a 416x496
panel.** A watch scene is a few dozen units deep; one cascade at 512 covers it:

```dart
scene.directionalLight = DirectionalLight(
  direction: vm.Vector3(-0.4, -1.0, -0.3),
  castsShadow: true,
  shadowCascadeCount: 1,     // default 4
  shadowMapResolution: 512,  // default 1024
  shadowMaxDistance: 30.0,   // default 150
);
```

That is 72 MB down to about 4.5 MB — measured on a Series 10, the render
graph's total went from 99.0 MB to 30.2 MB, and a scene that had been dying at
its first frame ran with shadows, tone mapping, colour grading, vignette *and*
bloom all enabled.

### 2. Textures, not polygon counts

Texture memory is resident and uncompressed, and it has nothing to do with the
file size on disk. A 2048x2048 RGBA map is **16 MB** whether it compresses to
40 KB or 4 MB. Photogrammetry and generated assets (Tripo, Luma, scans) ship
2048x2048 by default, usually three maps per model:

| per model | resident |
|---|---|
| 3 x 2048² | 48 MB |
| 3 x 512² | 3 MB |

Four such models is 192 MB of texture before a single frame is drawn — over the
budget on their own. On a 416x496 panel a prop is a few dozen pixels tall, so
512² is already generous; 256² is often indistinguishable.

Downscaling changes the *file* size hardly at all — the bytes are already
compressed — while cutting resident memory 16x. Judge assets by pixel
dimensions, never by megabytes on disk.

### 3. Geometry

Generated models arrive dense. A pair of toy scissors exported at **1,015,321
vertices** is normal for these tools and absurd for a watch. Budget under
~50K vertices per prop.

`gltf-transform` decimates without a modelling tool:

```sh
npx @gltf-transform/cli weld in.glb welded.glb
npx @gltf-transform/cli simplify welded.glb out.glb --ratio 0.08 --error 0.008
```

One caveat: these exports usually carry `EXT_meshopt_compression`, where the
real byte range lives in
`bufferView.extensions.EXT_meshopt_compression.byteOffset`, separate from the
bufferView's own `byteOffset`. Any script that rewrites the buffer must update
both, or the decoder reads garbage and the build hook fails with:

```
FormatException: EXT_meshopt_compression attribute stream has header byte 0x29,
expected 0xa0 or 0xa1
```

## Assets are shared, instances are not expensive

`loadScene()` caches per scene path. Calling it five times for the same `.glb`
builds five node graphs that **share** one set of geometry, materials, and
textures. You can verify it:

```dart
debugPrint('${takeMemoryReport()}');   // package:flutter_scene/scene.dart
```

Thirteen `loadScene()` calls across four distinct files report
`scene templates: 4`. Do not contort your code to avoid repeat loads — and note
that `takeMemoryReport()` counts the texture cache and template count, not the
geometry a template realized, so it will happily read `0.00 MiB` while the GPU
holds tens of megabytes.

## Bisecting a silent kill

Because the kill leaves no trace, print your way to it. Log before and after
each step; whichever line has a "begin" and no "end" is where the process died:

```dart
debugPrint('[probe] loading character');
character = await loadScene('assets/character.glb');
debugPrint('[probe] character done');
```

Two things this catches that reasoning does not:

- **The order of your loads decides what the evidence shows.** Disabling the
  last asset in a loading sequence proves nothing if the app dies on the second
  one. Bisect from the front.
- **Being over budget is cumulative, so the last straw is not the cause.** In
  one case bloom appeared to be fatal; it costs 2.2 MB. The app was sitting at
  ~298 MB because of the shadow atlas above, and bloom was merely what crossed
  the line. Fix the largest consumer, not the one that happened to be last.

To see exactly what the render graph pins, point `flutter_scene`'s pool hook at
a counter and read the `debugName`s:

```
directional_shadow_map        4096x1024  = 16.00MB
directional_shadow_map_depth  4096x1024  = 20.00MB
hdr_scene_color_msaa           422x514   =  6.62MB
scene_depth                    422x514   =  4.14MB
hdr_scene_color                422x514   =  1.65MB
bloom_down_0..4 / bloom_up_0..3          =  1.10MB
```

MSAA is worth a look too: `hdr_scene_color_msaa` and `scene_depth` at 4x
samples are ~19 MB together with double buffering.

## A budget that fits

An empty Flutter app on this engine starts at about **25 MB**, so budget
against the remaining ~275 MB. For a 3D app on a 416x496 watch:

| | budget |
|---|---|
| shadow atlas | ≤ 512x512, 1 cascade |
| textures | 512² per map |
| geometry | < 50K vertices per prop |
| unused assets | not in `pubspec.yaml` at all |

That last row is easy to forget: an asset declared in `pubspec.yaml` but never
loaded still ships. One 26.5 MB model that no code path touched was 20% of an
app bundle.
