# The build registry

When you run `flutter-watchos build watchos --release` while signed in, the
CLI tells your flutterwatch.dev account which app you just built. It prints a
line when it does:

```
✓ Built build/watchos/Release-watchos/Runner.app (12.4MB)
Registered this release build of com.example.watchface 1.4.0+27 with flutterwatch.dev.
```

That is what fills **My apps** in your [console](https://api.flutterwatch.dev/),
and it is how the project knows which apps ship the engine — the one number
that says whether flutter-watchos is worth maintaining, or sponsoring.

## Exactly what is sent

Four fields, in one HTTPS request, under your own account token:

| Field | Example | Where it comes from |
|---|---|---|
| `bundle_id` | `com.example.watchface` | `CFBundleIdentifier` of the built `Runner.app` |
| `app_version` | `1.4.0+27` | `CFBundleShortVersionString` + `CFBundleVersion` |
| `engine_version` | `engine-151920b726dc` | the engine id this CLI is pinned to |
| `build_mode` | `release` | always `release` — other modes are never registered |

## What is not

- No source code, file names, paths, dependency lists, or build logs.
- Nothing about your machine: no hostname, user name, OS version, or hardware id.
- Nothing from debug, profile, or simulator builds — only `--release`.
- **Nothing from your app, ever.** This happens on your machine at build time.
  Nothing is added to the app, the engine contains no telemetry, and an app
  you ship never contacts flutterwatch.dev. Your users are not part of this.

It never gets in the way of a build: it runs after the build has succeeded,
gives up after five seconds, and any failure — offline, a proxy, the service
being down — is ignored. If you are not signed in, nothing is sent.

## Turning it off

It is on by default. Any one of these turns it off:

```sh
flutter-watchos build-registry --disable            # this machine, until you --enable it
FLUTTER_WATCHOS_BUILD_REGISTRY=0                    # one shell, or a CI job
flutter-watchos build watchos --release --no-register-build   # one build
```

`flutter-watchos build-registry` on its own shows the current state. The
setting lives in `~/.flutter-watchos/settings.json`, separate from your
credentials, so signing out and in again does not switch it back on.

An app you would rather not name yet — an unannounced product, a client's
bundle id — is a perfectly good reason to turn it off. Nothing else about
your account changes.
