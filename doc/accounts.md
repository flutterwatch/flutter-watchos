# Accounts & engine artifacts

The watchOS engine ships as pre-built binaries downloaded from
flutterwatch.dev. Downloads are tied to your account; **during the closed
beta, access is by invite** — request access at
[flutterwatch.dev](https://flutterwatch.dev).

## Signing in

```sh
flutter-watchos login
```

Prints a URL and a short code (e.g. `AB2C-9XYZ`). Open the URL, sign in with
GitHub, confirm the code — the CLI detects the approval and stores an API
token in `~/.flutter-watchos/credentials.json` (file mode `600`). One login
per machine; tokens don't expire on a timer.

```sh
flutter-watchos logout   # removes the stored credentials
```

If a download is denied, the CLI prints the reason returned by the service
(not signed in, not in the beta yet, …) — the message tells you what to do.

## What gets downloaded

`flutter-watchos precache` (or the first build) fetches the engine set for
the pinned engine version: Simulator debug, device profile/release, and the
host AOT SDKs. Artifacts are cached under the CLI checkout's
`engine_artifacts/`; `precache --force` re-downloads.

## Environment variables

| Variable | Purpose |
|---|---|
| `WATCHOS_ARTIFACTS_API` | Override the artifact service base URL (mainly for testing; the production URL is built in). |
| `WATCHOS_ENGINE_ARTIFACTS` | Point at a local, pre-extracted engine directory — skips downloads entirely. For engine developers. |
| `WATCHOS_ENGINE_BASE_URL` | Legacy direct-download base URL override. Ignored when the artifact service is in use. |

## Privacy

The service records which engine versions your account downloads — that's
what ties access to accounts and tells us which engine versions are in use.
The engine itself contains **no telemetry**: apps you build never phone
home, and nothing is collected from your users.
