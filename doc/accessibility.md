# Accessibility

Flutter's accessibility works on watchOS. You annotate your app exactly the way
you would on any other platform — `Semantics`, `MergeSemantics`,
`ExcludeSemantics`, the semantics every Material and Cupertino widget already
carries — and VoiceOver reads and drives it on a real Apple Watch.

```dart
Semantics(
  label: 'Start workout',
  button: true,
  onTap: _start,
  child: const Icon(Icons.play_arrow),
)
```

Nothing here is watch-specific. If your app is accessible on iPhone, it is
accessible on the watch.

## What VoiceOver sees

The same tree Flutter builds everywhere:

| Flutter | VoiceOver on the watch |
|---|---|
| `label`, `value`, `hint`, `tooltip` | what it speaks (tooltip appended to the label, as on iOS) |
| `button`, `header`, `link`, `image`, `selected`, `toggled`, `checked` | the matching trait |
| `enabled: false` | announced as dimmed |
| `onTap` | activate (double tap) |
| `onIncrease` / `onDecrease` | adjustable — swipe up and down |
| `onLongPress`, `onDismiss`, `onExpand`, `onCollapse` | actions rotor |
| `CustomSemanticsAction` | actions rotor, under your label |
| scrollables | swiping past the last visible item scrolls the list |
| `TextField` | reads as a named text field and opens the keyboard |
| reading order | your traversal order, not screen geometry |

Platform views (`WatchPlatformView`) are read through the native SwiftUI view
they host, so a view you register brings its own accessibility — annotate it
with SwiftUI's modifiers rather than Flutter's.

## System settings

| Setting | Flutter |
|---|---|
| VoiceOver on | `MediaQuery.accessibleNavigation` |
| Reduce Motion | `MediaQuery.disableAnimations` |
| Text Size (and its Accessibility sizes) | `MediaQuery.textScaler` |

These update while your app is running, so an app that respects
`MediaQuery.textScaler` grows its text with the watch's own setting.

## What watchOS does not give us

**`SemanticsService.announce()` does nothing.** watchOS has no API to make a
screen reader speak an arbitrary string: UIKit's
`UIAccessibilityPostNotification` is unavailable there and SwiftUI has no
equivalent. The call is accepted and ignored. If a change matters to a VoiceOver
user, put it somewhere they can navigate to — a `liveRegion: true` node, or a
label that reflects the new state — instead of announcing it.

**Bold Text, Increase Contrast, and Invert Colours are not reported.** watchOS
exposes no query for them, so `MediaQuery.boldText`, `.highContrast`, and
`.invertColors` stay false rather than being guessed at.

## Not just VoiceOver

The semantics tree is what every assistive technology reads, and what UI
automation queries. Switch Control, AssistiveTouch, Xcode's Accessibility
Inspector and XCUITest all navigate it with VoiceOver switched off, so the tree
is always live — annotating your app pays off for automated testing as much as
for screen-reader users. `Semantics(identifier: ...)` becomes the element's
accessibility identifier, which is what an XCUITest query matches on.

## Testing it

Turn VoiceOver on for the watch in the iPhone's Watch app (My Watch →
Accessibility → VoiceOver), or press the Digital Crown three times if you have
the Accessibility Shortcut set. There is no meaningful VoiceOver on the watch
Simulator — verify on hardware.

`Semantics(identifier: ...)` also gives you a stable handle for XCUITest,
which works with VoiceOver off.
