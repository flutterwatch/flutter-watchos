# Layout on Apple Watch

An Apple Watch screen has rounded corners, and watchOS draws the time over
every app at the top of it. This page says what Flutter's safe area means on
the watch, what the stock widgets do with it, and how to lay out each kind of
screen around the corners and the clock.

## Two safe areas

The watch host reports `MediaQuery.padding` in one of two ways:

- **`corners`, the default.** The same inset on all four sides, 9 to 17 pt
  depending on the watch. It keeps content clear of the display's rounded
  corners only, so content can sit under the clock.
- **`platform`.** The insets watchOS itself reports, SwiftUI's
  `safeAreaInsets`. They keep content below the clock as well as clear of the
  corners: on Ultra 3, 56.5 pt at the top, 40 pt at the bottom and 2 pt at the
  sides.

**What sits under the clock is the app's responsibility.** The system draws
the clock over the app, and in `corners` mode nothing in the padding keeps
content out of its way. A screen whose content must not meet the clock takes
its top from `WatchStatusBar.heightOf` (see [The clock band](#the-clock-band)).

`corners` gives the app more of the screen: on Ultra 3 the padding rectangle
covers 73% of the display, against 61% in `platform` mode. The rectangle is
narrower, though, 177 pt wide instead of 207 pt.

In both modes `MediaQuery.viewPadding` equals `MediaQuery.padding`,
`viewInsets` and `systemGestureInsets` are zero, and hiding the clock changes
none of them.

### Choosing the mode

The app chooses with the `FlutterWatchOSSafeArea` key in
`watchos/Runner/Info.plist`, the file that also holds
[`FlutterWatchOSContentScale`](get-started.md#fitting-phone-designed-uis-content-scale).
To get the `platform` insets:

```xml
<key>FlutterWatchOSSafeArea</key>
<string>platform</string>
```

- The letter case does not matter: `platform`, `Platform` and `PLATFORM` all
  select `platform`.
- Any other value gives the default, `corners`: a missing key, `corners` in
  any letter case, any other string, and a value that is not a string.
- A watch the CLI does not know yet gets the `platform` insets in either mode.
  The host computes the corner inset from a table of display corner radii,
  keyed by screen size, and does not guess for a size it does not have.

### Keeping the layout from before 0.1.0

Before 0.1.0, `platform` was the default. From 0.1.0 every app gets `corners`
on its next build, with no change to its own code: a `ListView` with no
`padding` starts its first row under the clock, and an `AppBar` moves up into
the clock's band. To keep the earlier layout, where the padding also keeps
content below the clock, add `FlutterWatchOSSafeArea` with the value
`platform` to `watchos/Runner/Info.plist`:

```xml
<key>FlutterWatchOSSafeArea</key>
<string>platform</string>
```

## The clock band

The clock sits in a band across the top of the screen. The band's height is
the top inset watchOS reports: from 40 pt on SE 3 40 mm to 56.5 pt on Ultra 3
and 4 (see [Numbers per watch](#numbers-per-watch)). In `platform` mode it is
the top of `MediaQuery.padding`. In `corners` mode the padding does not carry
it, and `package:flutter_watchos` gives it instead:

```dart
final double band = WatchStatusBar.heightOf(context);
```

`WatchStatusBar.heightOf(context)` is the band's height in logical pixels,
measured from the top of the view, in both modes:

- It is for content that starts at the top of the view. Content below an
  `AppBar` or inside a `SafeArea` already starts below its ancestor's top
  edge, so do not add the band again there.
- It is the same whether the clock is shown or hidden.
- Under content scale it is divided by the scale, as the padding is.
- Off the watch, on the Web, and on a watch whose host does not report the
  band (an app built with a CLI older than 0.1.0, where `platform` was the
  default), it is the view's own top padding. A `SafeArea` or an `AppBar`
  above `context` does not change that value.
- Calling it makes `context` depend on the `MediaQuery` padding, so the caller
  rebuilds when the padding it sees changes.

**Known limit.** The caller rebuilds when its padding changes, not when the
band alone does. In `corners` mode the padding is the corner inset, which does
not follow watchOS's top inset. If watchOS changed its top inset while the
corner inset stayed the same, the engine would send no new metrics, and the
caller would keep the old band until something else rebuilt it. No such
change has been measured: in every Simulator launch the insets were in place
at the first frame and did not change.

## What the stock widgets do

Flutter's widgets read the watch's insets the way they read an iPhone's. What
changes on the watch is the size of the clock's band, or, in `corners` mode,
that the padding leaves the band out. A new project from
`flutter-watchos create` starts from Flutter's counter app, with an `AppBar`,
a centred counter and a floating action button, so what follows is also what
that app does on the watch until it is adapted.

### Under `corners`, the default

Measured on 11 Simulator configurations covering all 8 screen sizes. Where a
bullet names the counter page, it is the one stock `flutter create` writes:

- `SafeArea` insets by the corner inset, 9 to 17 pt, on all four sides, so its
  top edge is inside the clock's band. On Ultra 3 its child spans y 17 to 240
  and x 17 to 194; on SE 3 40 mm, y 9 to 188 and x 9 to 153.
- A `ListView` or `GridView` with `padding` left null starts row 0 at the
  corner inset, under the clock, and scrolls to the corner inset at the
  bottom. It leaves the 9 to 17 pt side insets to its rows, so a plain `Text`
  row runs from edge to edge and loses glyphs to the corner curve near the top
  and the bottom.
- A list whose own `padding` adds `MediaQuery.paddingOf(context)` gets the
  same corner inset. A list that must start below the clock takes its top
  from `WatchStatusBar.heightOf(context)`.
- An `AppBar` is 65 to 73 pt tall, 28% to 33% of the screen height. Its
  toolbar row starts inside the clock's band, the clock is drawn over it, and
  the side insets narrow its title. On the counter page the title was cut on
  the smallest and the largest watch, and sat just below the clock's digits.
- `Scaffold`'s floating action button sits 16 pt plus the corner inset from
  the edges. On the counter page on SE 3 40 mm it covered the counter.
- `Scaffold` gives its body no side padding, so text in the body can start at
  the left edge, as it did on the counter page.
- Slivers and `SingleChildScrollView` never pad themselves. `SliverSafeArea`
  insets by the corner inset.

### Under `platform`

The widgets behave as they did before 0.1.0, when `platform` was the default:

- `SafeArea` insets by watchOS's insets, so its child starts below the clock,
  ends above the bottom inset and keeps 2 pt from the sides.
- A `ListView` or `GridView` with `padding` left null starts row 0 below the
  clock, scrolls its rows under the clock, and runs them to the bottom edge of
  the display, as a native watchOS list does. It leaves the 2 pt side insets
  to its rows.
- An `AppBar` ends at the clock's band plus its 56 pt toolbar: 96 to 112.5 pt,
  44% to 49% of the screen height.
- `Scaffold`'s floating action button sits 16 pt plus the insets from the
  edges.
- Slivers and `SingleChildScrollView` never pad themselves. `SliverSafeArea`
  insets by watchOS's insets.

## Laying out each kind of screen

The samples below import these libraries:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_watchos/flutter_watchos.dart';
```

The shorter samples are expressions inside a `build` method, where `rows` is a
`List<Widget>`.

### Scrolling lists

This covers `ListView`, `GridView` and `ListView.builder`. A watchOS list
covers the whole screen and scrolls its rows under the clock and down to the
bottom edge.

Do:

- In either mode, let the list cover the whole screen.
- Under `corners`, decide where the first row starts. With `padding` left
  null it starts at the corner inset, beside and under the clock. Then give
  every row's text a side margin of at least the corner inset (see
  [Text margins](#text-margins)), and keep the first row clear of the clock,
  as [The title](#the-title) describes.
- Under `corners`, a list whose first row must start below the clock takes
  its top from `WatchStatusBar.heightOf`, as in the sample below.
- Under `platform`, leave `padding` null: row 0 starts below the clock. The
  side inset is 2 pt, so give text a margin of its own.
- With your own `padding`, add the insets to it. The sample does that, and
  starts below the clock in either mode, because under `platform` the band is
  the padding's top.

Don't:

- Wrap a scrolling list in a `SafeArea`. The list becomes a window between the
  insets, and no row ever shows above or below it. Under `platform` that
  window is 62% to 70% of the screen height.
- Give a list a fixed `padding`, such as `EdgeInsets.all(8)`, that ignores the
  insets. In either mode row 0 then starts under the clock and the rows run
  into the corners.
- Put a `SafeArea` inside a row of a list that has its own `padding`. A list
  with `padding` left null takes the top and bottom insets itself and passes
  only the side insets to its rows. A list with an explicit `padding` passes
  the full `MediaQuery.padding` to its rows, so a `SafeArea` inside a row
  insets a second time.

A list that starts below the clock, in either mode:

```dart
class SettingsList extends StatelessWidget {
  const SettingsList({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets insets = MediaQuery.paddingOf(context);
    return Scaffold(
      body: ListView(
        // The first row starts below the clock's band, and the rows scroll
        // under it. The sides keep at least 10 pt and at least the side inset.
        padding: EdgeInsets.fromLTRB(
          math.max(10, insets.left),
          WatchStatusBar.heightOf(context),
          math.max(10, insets.right),
          insets.bottom,
        ),
        children: rows,
      ),
    );
  }
}
```

### `CustomScrollView`

Do: put the slivers in a `SliverSafeArea`. It pads by the insets and removes
them from what its slivers see, so nothing inside insets twice. Under
`corners` that puts the first sliver at the corner inset, under the clock; to
start below the clock, give `minimum` a top of `WatchStatusBar.heightOf`.
`SliverSafeArea` takes the larger of each inset and `minimum`, so the same
code works under `platform`:

```dart
CustomScrollView(
  slivers: <Widget>[
    SliverSafeArea(
      minimum: EdgeInsets.fromLTRB(
        10,
        WatchStatusBar.heightOf(context),
        10,
        0,
      ),
      sliver: SliverList.list(children: rows),
    ),
  ],
)
```

Don't: leave the slivers bare. In either mode the first one starts at y 0,
under the clock and in the corners. Don't wrap the `CustomScrollView` in a
`SafeArea` either: like a list, it becomes a window between the insets.

### `SingleChildScrollView`

It never pads itself.

Do: give it the insets as its `padding`, with the top from
`WatchStatusBar.heightOf` under `corners` when its content must start below
the clock, as the list sample does. Or put a `SafeArea` inside it, around its
child. The simplest form:

```dart
SingleChildScrollView(
  padding: MediaQuery.paddingOf(context),
  child: Column(children: rows),
)
```

Don't: wrap it in a `SafeArea`. Like a list, it becomes a window between the
insets.

### Fixed screens

A screen that does not scroll.

Do:

- Put the content in a `SafeArea`. Under `platform` that keeps it below the
  clock and clear of the corners.
- Under `corners` the `SafeArea`'s top edge is inside the clock's band, so
  give its `minimum` a top of `WatchStatusBar.heightOf` to keep controls out of
  the band. Add a side minimum for text. The sample does both, and works in
  either mode.
- Prefer full-width buttons, and at most two text buttons in a row, as
  Apple's guidelines ask.
- Let the screen scroll when the text grows. Apple asks watch apps to let
  text grow to 140%; a fixed screen that overflows at a large Text Size
  becomes a `SingleChildScrollView`.

Don't:

- Use `SafeArea(top: false)`. In either mode its top corners are then off the
  glass.
- Put a tappable control in the clock's band.

A fixed screen that keeps its controls out of the clock's band, in either
mode:

```dart
class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // SafeArea takes the larger of each inset and this minimum: the top
        // below the clock's band, the sides at least 8 pt in.
        minimum: EdgeInsets.fromLTRB(
          8,
          WatchStatusBar.heightOf(context),
          8,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: BackButton(),
            ),
            const Expanded(
              child: Center(
                child: Text('25:00', style: TextStyle(fontSize: 40)),
              ),
            ),
            FilledButton(onPressed: onStart, child: const Text('Start')),
          ],
        ),
      ),
    );
  }
}
```

### Full-bleed art and games

Do: paint the whole screen, with no `SafeArea` around the canvas, and put a
`SafeArea` around the score, the HUD and the controls only. Under `corners`
that `SafeArea` puts them at the corner inset, under the clock: either hide
the clock for the game (see [A hidden clock](#a-hidden-clock)), or give the
`SafeArea` a `minimum` top of `WatchStatusBar.heightOf`. Under `platform` the
`SafeArea` keeps them below the clock.

Don't: wrap the canvas in a `SafeArea`. That letterboxes the art.

`MediaQuery.displayCornerRadiiOf` returns null on the watch, as it does on
iOS. A game that needs the exact corner shape keeps its own table.

### The title

A watchOS app puts its title at the top of its list. A native
`navigationTitle` sits beside the clock, and the list starts below it.

Do:

- Make the title the first row of the list.
- Under `corners`, with `padding` left null, that row starts at the corner
  inset, beside the clock. In every Simulator run measured for this page the
  clock sat at the top right, so keep the title to the leading half of the
  width, let it wrap rather than cut it, and keep anything tappable out of
  that row. The sample below does this.
- Under `corners`, a list that starts at `WatchStatusBar.heightOf` puts the
  title below the clock instead, where it can take the full width. So does
  `platform`, with `padding` left null.

Don't:

- Put a tappable control, or a title that can run into the clock, in the
  clock's band.

An `AppBar` is the counter app's title. Keeping it costs the space and the
overlap listed in [What the stock widgets do](#what-the-stock-widgets-do):
under `platform` it takes 44% to 49% of the screen height, and under `corners`
its toolbar row starts inside the clock's band, where the clock is drawn over
it. Moving the title into the list's first row, as below, adapts it.

A title beside the clock, under `corners`:

```dart
class HomeList extends StatelessWidget {
  const HomeList({super.key, required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    // A ListView with no padding leaves the side insets to its rows, so each
    // row keeps at least 10 pt and at least the side inset.
    final EdgeInsets insets = MediaQuery.paddingOf(context);
    final EdgeInsets rowPadding = EdgeInsets.only(
      left: math.max(10, insets.left),
      right: math.max(10, insets.right),
    );
    return Scaffold(
      body: ListView(
        children: <Widget>[
          // The first row is beside the clock, so the title keeps to the
          // leading half of the width and wraps there.
          Padding(
            padding: rowPadding,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
          for (final Widget row in rows)
            Padding(padding: rowPadding, child: row),
        ],
      ),
    );
  }
}
```

### A hidden clock

`WatchStatusBar.hidden = true` hides the clock, for a game or a full-bleed
screen. In either mode it changes neither `MediaQuery.padding` nor
`WatchStatusBar.heightOf`.

- Under `corners` the app already has the band. Content at the padding's top
  starts at the corner inset, where the clock was. A list that starts at
  `WatchStatusBar.heightOf` leaves the band empty, so while the clock is
  hidden, start it at the padding's top instead.
- Under `platform` the padding's top stays the band, which then shows the
  app's background. To use it, reclaim the top with the recipe below.

Don't expect a `SafeArea` to reclaim the band. It follows the padding, and the
padding does not change.

#### Reclaiming the top under `platform`

This recipe is for apps that set `FlutterWatchOSSafeArea` to `platform`. Under
the default it changes nothing, because the padding is already the same on all
four sides.

While the app keeps the clock hidden, give the screen the bottom inset at the
top as well:

```dart
/// While the app keeps the clock hidden, gives [child] the bottom inset at
/// the top, so it can use the band the clock left.
class ReclaimTop extends StatelessWidget {
  const ReclaimTop({
    super.key,
    required this.clockHidden,
    required this.child,
  });

  /// What the app set with `WatchStatusBar.hidden`.
  final bool clockHidden;

  /// The screen that uses the reclaimed top.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // On a phone the top inset is the status bar and the bottom one the home
    // indicator, so mirroring them there would be wrong.
    if (!clockHidden || !FlutterWatchosPlatform.isWatch) {
      return child;
    }
    final MediaQueryData data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(
        padding: data.padding.copyWith(top: data.padding.bottom),
        viewPadding: data.viewPadding.copyWith(top: data.viewPadding.bottom),
      ),
      child: child,
    );
  }
}
```

The app passes `clockHidden` itself, so the screen rebuilds when the app
changes it. With the clock hidden, a `ListView` with `padding` left null then
starts its first row at the bottom inset: on the Simulator, 19 pt on SE 3
40 mm, 31 pt on 42 mm and 40 pt on Ultra 3.

The reclaimed top is as safe as the bottom edge, and no safer. The display
has nearly the same shape at the top as at the bottom, so the top corners of
the reclaimed rectangle sit where watchOS puts the bottom corners of its own
safe area: 0 to 1.5 pt off the glass, the most on Ultra 3 and 4. Only content
drawn into those exact corners notices.

### Going back

A screen without an `AppBar` has no back button. Give every pushed screen an
explicit back control, as the crown screen of the
[`flutter_watchos` example](../packages/flutter_watchos/example/lib/main.dart)
does: Material's `BackButton`, or an `IconButton` that pops the route. Place
it where it does not meet the clock; the fixed screen above puts it below the
band.

## Text margins

Under `corners`, a row's text needs a side margin of at least the corner inset
where the row sits near the top or the bottom of the screen. A `ListView` with
`padding` left null leaves that inset to its rows, and at the height of the
corner inset the glass starts about one corner inset in from the side: for a
circular corner of the display's radius, 7.4 pt in on SE 3 40 mm and 16.4 pt
in on Ultra 3. On the Simulator, `Text` rows that started at x = 0 lost their
first and last glyphs. The side inset is `MediaQuery.paddingOf(context).left`
and `.right`, which under `corners` is the corner inset, so a margin of
`math.max(10, inset)` covers both modes. The samples above use it.

As a rule of thumb, keep text about 8 to 10 pt from the sides of the screen;
backgrounds and buttons can run out to the side inset. This is only a rule of
thumb: Apple aligns text with the system's minimum layout margins and
publishes no current number for them on the watch.

## Content scale

[`FlutterWatchOSContentScale`](get-started.md#fitting-phone-designed-uis-content-scale)
scales the insets but not the 56 pt `AppBar` toolbar.

- The host divides the insets by the scale, so they keep their size on the
  screen. On Ultra 3 at 0.6, measured on the Simulator, `platform` reports
  94.17 pt at the top, 66.67 pt at the bottom and 3.33 pt at the sides, and
  `corners` 28.33 pt on every side. The host divides the clock's band the same
  way, so there `WatchStatusBar.heightOf` returns 56.5 / 0.6 = 94.17.
- The `AppBar` toolbar stays 56 logical pixels, so on the screen it shrinks
  with the rest of the layout, to 33.6 pt at 0.6.
- A text margin given in logical pixels shrinks on the glass in the same way:
  10 logical pixels are 6 pt at 0.6. A margin taken from the insets, such as
  `math.max(10, inset)` under `corners`, keeps its size.

## Numbers per watch

These are Simulator measurements, in points at content scale 1.0: Xcode 27.0,
watchOS 27.0, and watchOS 26.5 for SE 3 44 mm. On every configuration, the
padding Flutter received in `platform` mode equalled the `safeAreaInsets` of a
native SwiftUI app, and the padding in `corners` mode equalled the corner
inset the host computes from the display's corner radius.

| Screen | Measured on | `platform` T / B / sides | `corners` | Band |
|---|---|---|---|---|
| 162x197 | SE 3 40 mm | 40 / 19 / 2 | 9 | 40 |
| 176x215 | Series 9 41 mm | 46 / 26 / 2 | 12 | 46 |
| 184x224 | SE 3 44 mm | 46.5 / 22 / 2 | 10 | 46.5 |
| 187x223 | Series 10 and 12 42 mm | 48 / 31 / 2 | 13 | 48 |
| 198x242 | Series 9 45 mm | 51 / 27 / 2 | 13 | 51 |
| 205x251 | Ultra 2 | 55 / 39 / 2 | 16 | 55 |
| 208x248 | Series 12 46 mm | 53 / 36 / 2 | 15 | 53 |
| 211x257 | Ultra 3 and 4 | 56.5 / 40 / 2 | 17 | 56.5 |

- **`platform`**: the top, bottom and side insets.
- **`corners`**: the inset on all four sides.
- **Band**: the clock's band, which `WatchStatusBar.heightOf` returns in both
  modes. It is the `platform` top inset.

Other watches with the same screen size, such as Series 10 and 11 46 mm, have
the same corner radius in the host's table and the same display shape in the
Simulator. Their `platform` insets were not measured separately.

The one check on a physical watch: a Series 10 46 mm, in `platform` mode,
reported 53 / 36 / 2, the same as the Simulator's 46 mm row. Every other
number on this page comes from the Simulator.
