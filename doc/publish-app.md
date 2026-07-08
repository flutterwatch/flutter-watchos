# Publish an app

A standalone (watch-only) app ships to the App Store with the same commands
you already use, plus Xcode's Archive/Organizer for the final signing step:

```sh
flutter-watchos build watchos --release   # release build of the watch app
# then in Xcode: open watchos/Runner.xcodeproj →
#   Product → Archive → Distribute App → App Store Connect
```

The version comes from `pubspec.yaml` (`version: 1.2.0+3` → `1.2.0` /
build `3`), so a release is: bump the pubspec, `build watchos --release`,
archive in Xcode, distribute.

## How submission works

App Store submission wraps a watch-only app in a thin iOS container
(`ITSWatchOnlyContainer`) with the watch app embedded at `Watch/Runner.app`.
Your project ships that container as a code-less **`watchapp2-container`**
target (created by `flutter-watchos create`) that embeds the watch app and
its frameworks. Because the `Runner` scheme is wired to archive the
container, **Product → Archive** produces the distributable app — it shows up
under "iOS Apps" in the Organizer with the **App Store Connect** distribution
option (a watch app archived on its own is a "Generic Xcode Archive" with no
distribution options — archive the `Runner`/`<app>` scheme, not a bare watch
target).

Xcode does the container assembly, slice thinning, and signing. If you'd
rather script it, export an `.ipa` from the Organizer (or `xcodebuild
-exportArchive`) and hand it to `flutter-watchos upload` — see below.

## One-time setup

1. **App Store Connect record** — create the app (platform iOS) with your
   bundle id, e.g. `com.acme.myapp`.
2. **Certificates** — an **Apple Distribution** certificate in your keychain
   (Xcode → Settings → Accounts → Manage Certificates, or the developer
   portal).
3. **Provisioning profiles** — none to create by hand. With "Automatically
   manage signing" enabled, Xcode creates and manages the two App Store
   profiles it needs — `com.acme.myapp` (the container) and
   `com.acme.myapp.watchkitapp` (the embedded watch app). (Projects created
   by `flutter-watchos create` use `<org>.<app>` for the container and
   `<org>.<app>.watchkitapp` for the watch app.)
4. **API key** (optional, for CLI `upload`) — an App Store Connect API key
   (Users and Access → Integrations, role App Manager). Put the `.p8` in
   `~/.appstoreconnect/private_keys/` and pass the key id + issuer id to
   `upload` (or export `APP_STORE_CONNECT_API_KEY_ID` /
   `APP_STORE_CONNECT_API_ISSUER`). Distributing straight from the Xcode
   Organizer doesn't need this.

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
- [ ] `flutter-watchos build watchos --release` succeeds
- [ ] Xcode archive succeeds and shows the App Store Connect distribution
      option (archive the `Runner`/`<app>` scheme, not a bare watch target)
- [ ] Build appears in App Store Connect → TestFlight after processing
