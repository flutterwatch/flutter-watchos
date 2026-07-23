# Contributing to flutter-watchos

Thanks for your interest in contributing. The CLI is BSD 3-Clause licensed
and contributions are welcome — no CLA required. (The engine is distributed
as pre-built binaries and is not part of this repository.)

## Reporting bugs

Open an issue on GitHub. Please include:

- `flutter-watchos --version` output
- macOS version (`sw_vers`) and Xcode version (`xcodebuild -version`)
- Whether it happened on the Simulator or a physical watch (and which model)
- Full error output (use code blocks), and `-v` output if relevant
- Steps to reproduce

## Submitting a pull request

This repo uses a two-line branch model:

- **`dev`** — integration branch. Base your work here and open PRs against it.
- **`main`** — the always-releasable line; it receives work only as release
  merges (see below), so a feature PR against `main` is almost always wrong.

1. Fork the repository and create a branch from `dev`
2. Make your changes
3. Run the test suite and static analysis (below)
4. Open a PR against `dev` describing what changed and why

Keep PRs focused — one logical change per PR. The
[pull-request template](.github/PULL_REQUEST_TEMPLATE.md) lists the full bar.

## Release process

Releases are cut by merging **`dev → main` with an explicit merge commit** —
never a fast-forward — so each release lands on `main` as one milestone commit
while the individual feature commits stay granular on `dev`.

Before cutting, on `dev`: make sure it is green on CI, roll `CHANGELOG.md`'s
**Unreleased** section into the new version heading, and bump the version
wherever it is stated (e.g. `README.md`).

```bash
git checkout main
git pull --ff-only origin main

# --no-ff is the point: one merge commit per release.
git merge --no-ff dev -m "Release <version>: <summary>"

git tag -a v<version> -m "v<version>"   # optional but recommended
git push origin main --follow-tags
```

Prefer to review the release as a whole? Open a `dev → main` pull request and
merge it with GitHub's **"Create a merge commit"** button instead — that is the
same `--no-ff` merge, with CI and a visible diff. Either way, never fast-forward
or squash `dev` onto `main`; that would collapse the release boundary this model
exists to preserve. See [.github/BRANCH_PROTECTION.md](.github/BRANCH_PROTECTION.md).

## Running tests

The pinned Flutter SDK is bootstrapped into `flutter/` the first time you
run any `flutter-watchos` command. Then, from the repo root:

```bash
flutter/bin/dart analyze --fatal-warnings
flutter/bin/dart test test/general
```

The tests use Flutter's own test infrastructure (`FakeProcessManager`,
`testWithoutContext`, `testUsingContext`) and need no device or simulator.
CI runs exactly these two commands.

## Code style

- Follow the patterns already in the codebase; match Flutter SDK
  conventions (naming, structure, error handling)
- Keep command implementations thin — logic belongs in helpers that can be
  unit-tested
- Template changes (`templates/`) that affect text input or crown handling
  must keep `test/general/watchos_text_input_test.dart` green — those are
  contract tests for behaviour that is verified manually on the Simulator
