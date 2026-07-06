# Publish an app

A standalone (watch-only) app ships to the App Store entirely from the
terminal:

```sh
flutter-watchos archive   # release build → signed App Store .ipa
flutter-watchos upload    # validate + upload to App Store Connect
```

The version comes from `pubspec.yaml` (`version: 1.2.0+3` →
`1.2.0` / build `3`), so a release is: bump the pubspec, `archive`, `upload`.

## Why a dedicated command

App Store submission wraps a watch-only app in a thin iOS container
(`ITSWatchOnlyContainer`) with the watch app embedded at `Watch/Runner.app`.
Xcode 26 only performs that packaging in the Organizer UI — `xcodebuild
-exportArchive` no longer offers App Store distribution for watch-only
archives. `flutter-watchos archive` produces the same container itself
(validated against App Store Connect), which keeps the whole release
scriptable and CI-friendly.

## One-time setup

1. **App Store Connect record** — create the app (platform iOS) with your
   bundle id, e.g. `com.acme.myapp`.
2. **Certificates** — an **Apple Distribution** certificate in your keychain
   (Xcode → Settings → Accounts → Manage Certificates, or the developer
   portal).
3. **Provisioning profiles** — two App Store profiles, downloaded and
   double-clicked so Xcode installs them:
   - one for `com.acme.myapp` (the container),
   - one for `com.acme.myapp.watchkitapp` (the embedded watch app).
   (Projects created by `flutter-watchos create` use
   `<org>.<app>.watchkitapp` as the Xcode bundle id; `archive` derives the
   container/watch id pair from it automatically, so either form works.)
4. **API key** — an App Store Connect API key (Users and Access →
   Integrations, role App Manager). Put the `.p8` in
   `~/.appstoreconnect/private_keys/` and pass the key id + issuer id to
   `upload` (or export `APP_STORE_CONNECT_API_KEY_ID` /
   `APP_STORE_CONNECT_API_ISSUER`).

## Test before you ship

```sh
flutter-watchos run -d <watch-id> --release   # release build on a real watch
flutter-watchos upload --validate-only        # App Store checks, no upload
```

## Companion apps (iOS app + watch app)

If your project also ships an iOS app, the watch app is embedded in the iOS
host and submitted as a normal iOS build — archive the `ios/` project and
export with method `app-store-connect` (works fine in `xcodebuild`), or use
Xcode. First-class companion wiring in `flutter-watchos create`/`build` is
on the roadmap.

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

- [ ] `version:` bumped in pubspec.yaml (App Store rejects duplicates)
- [ ] Release build runs on a physical watch
- [ ] App icons + `Info.plist` metadata set in `watchos/Runner`
- [ ] Deployment-target decision made (stub fallback vs. 27.0+)
- [ ] `flutter-watchos archive` succeeds
- [ ] `flutter-watchos upload` — build appears in App Store Connect →
      TestFlight after processing
