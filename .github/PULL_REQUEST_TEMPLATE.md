<!--
Base branch: target `dev`. `main` receives work only as a release merge
(`git merge --no-ff dev`), so a feature/fix PR into `main` is almost always
wrong — retarget it to `dev`.
-->

**What this changes**

<!-- One or two sentences. Link the issue if there is one (Fixes #123). -->

**Type**

<!-- Delete what doesn't apply. -->
feature / fix / docs / refactor / test / chore

**How it was verified**

<!-- The CI gate is analyze + unit tests; say what you ran BEYOND that. -->

- Simulator: <!-- watchOS version + what you exercised, or "n/a" -->
- Physical watch: <!-- model + watchOS version, or "n/a" — required for anything the Simulator can't prove (Always-On, crown feel, AOT identity, FFI symbol survival) -->

**Checklist**

- [ ] `./flutter/bin/dart analyze --fatal-warnings` is clean
- [ ] `./flutter/bin/dart test test/general` passes
- [ ] Logic lives in unit-testable helpers with tests (not just in command glue)
- [ ] No closed-source engine internals in any public-facing file — docs, templates, error strings, marketing (describe *what* watchOS can't do, never *how* the engine works)
- [ ] Nothing untracked-by-policy slipped in: no `flutter/`, `engine_artifacts/`, real Development Team ids, tokens, or other secrets
- [ ] `PROGRESS.md` updated if this moves a tracked item (and doesn't claim a physical-watch result the Simulator can't give)
- [ ] Commits carry no AI-attribution / co-author trailer

**Notes for the reviewer**

<!-- Anything non-obvious: a tricky merge, a deliberate omission, a follow-up you deferred. -->
