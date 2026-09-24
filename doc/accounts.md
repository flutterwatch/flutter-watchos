# Accounts & engine artifacts

The watchOS engine ships as pre-built binaries downloaded from
flutterwatch.dev.

| Engine | Used for | Account |
|---|---|---|
| Simulator (debug) | `run` and `build --simulator`, hot reload | not needed |
| Device (profile, release) and the host SDKs | a physical watch, App Store builds | needed |

Getting an account is **self-serve and instant**: `flutter-watchos login` is
all it takes. The page it opens signs you in with GitHub, and that creates the
account — there is no separate sign-up, no form to fill in and no invite to
wait for. Your console at [api.flutterwatch.dev](https://api.flutterwatch.dev/)
shows the account, its keys and the apps you ship.

## Signing in

```sh
flutter-watchos login
```

Prints a URL and a short code (e.g. `AB2C-9XYZ`). Open the URL, sign in with
GitHub, confirm the code — the CLI detects the approval and stores an API
token in `~/.flutter-watchos/credentials.json` (file mode `600`). One login
per machine; tokens don't expire on a timer.

```sh
flutter-watchos logout   # revokes this machine's sign-in, then removes it
```

`logout` asks the service to revoke the token before it deletes the file. If
the service cannot be reached, the file goes anyway and `logout` says the
token stays valid until you revoke it in your console.

Signed out, `precache` installs the Simulator engine and lists the others as
"needs an account, skipped". After `login`, the next build downloads only the
missing engines (or run `flutter-watchos precache` to fetch them straight
away). A profile or release build on a machine that is not signed in stops
early and says the same thing. `flutter-watchos doctor` shows which engines
are installed and whether the machine is signed in.

If a download is denied for any other reason, the CLI prints the reason
returned by the service — the message tells you what to do. An account the
service has switched off still gets the Simulator engine. Which engines an
account gets is decided by the service, not by the CLI version you have.

## What gets downloaded

`flutter-watchos precache` (or the first build) fetches the engine set for
the pinned engine version: Simulator debug and — signed in — device
profile/release and the host AOT SDKs. Artifacts are cached under the CLI checkout's
`engine_artifacts/`; `precache --force` downloads them all again, and keeps
the engine you had if that download fails. An engine directory you built
yourself (`WATCHOS_ENGINE_ARTIFACTS`) is never deleted.

## Environment variables

| Variable | Purpose |
|---|---|
| `WATCHOS_ARTIFACTS_API` | Override the artifact service base URL (mainly for testing; the production URL is built in). |
| `WATCHOS_ENGINE_ARTIFACTS` | Point at a local, pre-extracted engine directory — skips downloads entirely. For engine developers. |
| `WATCHOS_ENGINE_BASE_URL` | Legacy direct-download base URL override. Ignored when the artifact service is in use. |
| `FLUTTER_WATCHOS_BUILD_REGISTRY` | Set to `0` to stop release builds being registered with your account — see [the build registry](build-registry.md). |

## Privacy

The service records which engine versions are downloaded, and by which
account when you are signed in — that tells us which engine versions are in
use. A download made without an account is counted without one.

A successful **release** build also registers itself with your account: the
bundle id, app version, engine id and build mode — four fields, sent once, at
build time, from your machine. It is on by default, it says so when it happens,
and it is one command away from off. [The build registry](build-registry.md)
lists exactly what is and is not sent.

Apart from signing in and out, that is all the CLI sends. There is no usage
analytics, and the engine
contains **no telemetry**: apps you build never phone home, and nothing is
collected from your users.

Full details — what an account stores, what is deliberately not collected,
and which third parties are involved — are at
[flutterwatch.dev/privacy](https://flutterwatch.dev/privacy).
