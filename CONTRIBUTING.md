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

1. Fork the repository and create a branch from `main`
2. Make your changes
3. Run the test suite and static analysis (below)
4. Open a PR against `main` describing what changed and why

Keep PRs focused — one logical change per PR.

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
