# Publish an app

## Build for release

```sh
flutter-watchos build watchos --release
```

This AOT-compiles your Dart code and produces a signed watch `Runner.app`.
Requirements:

- Xcode code signing configured with your development team (open
  `watchos/Runner.xcodeproj` once and set the team, or set
  `DEVELOPMENT_TEAM` in the project).
- Release engine artifacts on your machine — downloads are tied to your
  flutterwatch.dev account ([accounts.md](accounts.md)).

Test the release build on a physical watch before submitting:

```sh
flutter-watchos run -d <watch-id> --release
```

## The iOS container

Unlike tvOS, a watch app is **not submitted standalone**: App Store
submission packages the watch app inside a thin iOS host container
(`ITSWatchOnlyContainer`), with the watch app embedded at
`Watch/Runner.app`. The container is a shell — your Flutter code runs
entirely on the watch.

Archive and upload through Xcode (Product → Archive → Distribute) or
`xcodebuild -exportArchive`, exactly as for a native watch-only app.

## arm64_32 and the deployment target

The App Store requires an `arm64_32` slice in the watch executable when
`WATCHOS_DEPLOYMENT_TARGET < 27.0`. The Flutter engine is arm64-only
(Apple Watch Series 9 / Ultra 2 and later), so the template handles this
with a stub `arm64_32` slice that shows a "Requires Apple Watch Series 9 or
later" screen on older hardware. You have two options:

1. **Keep the default** (deployment target < 27.0 + stub): the app installs
   on older watches but shows the fallback screen there. Say so in your App
   Store description.
2. **Set `WATCHOS_DEPLOYMENT_TARGET` to 27.0+**: no stub needed; the App
   Store simply won't offer the app to unsupported watches.

Only the watch *executable* needs the fat slice — embedded frameworks stay
arm64-only either way.

## Checklist

- [ ] `flutter-watchos build watchos --release` succeeds
- [ ] Release build runs on a physical watch
- [ ] App icons + `Info.plist` metadata set in `watchos/Runner`
- [ ] Deployment-target decision made (stub fallback vs. 27.0+)
- [ ] Archive validates in Xcode's Organizer (watch-only container checks,
      including ITMS-90426-style framework layout, surface here)
