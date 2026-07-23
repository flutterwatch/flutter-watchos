# Branch protection — recommended settings

Notes, not automation. These are configured in the GitHub UI
(**Settings → Branches → Branch protection rules**) or via `gh api`; nothing in
the repo enforces them. They match the two-line workflow: features on `dev`,
releases merged `dev → main` with `--no-ff`.

## `main` — the always-releasable line

The goal is: `main` never holds un-CI'd code, and every arrival is a release
milestone. There's one tension to decide first, because it changes everything
else.

**How do you cut a release?**

- **A. Local merge, then push** — `git merge --no-ff dev && git push origin main`.
  This is the flow we adopted. It is *incompatible* with "Require a pull request
  before merging" (that rule blocks all direct pushes). So protect `main` with:
  - ✅ **Require status checks to pass** → select the CI check **`analyze-and-test`**
  - ✅ **Require branches to be up to date before merging**
  - ⬜️ **Require a pull request before merging** — leave OFF (it would block the
        local release push)
  - ⬜️ **Do not allow bypassing the above** — leave OFF, so the maintainer can
        push the release merge (status checks still apply on the next push)
  - ✅ **Require linear history** — leave OFF; `--no-ff` release merges are the
        whole point, and this rule forbids merge commits.

- **B. Release via PR** (stronger, if you ever add collaborators) — open a
  `dev → main` PR and click **"Create a merge commit"** (GitHub's merge-commit
  option *is* a `--no-ff` merge, so the milestone history is identical). Then you
  can turn ON **Require a pull request before merging** and **Do not allow
  bypassing**, keeping every other setting above. This is the recommended target
  state once more than one person pushes.

Either way: keep **Allow force pushes** and **Allow deletions** OFF on `main`.

## `dev` — the integration branch

Lighter. It's meant to move fast and hold in-progress work.

- ✅ **Require status checks to pass** → `analyze-and-test` (so a red `dev`
      surfaces immediately, before it ever reaches a release)
- ⬜️ Require PRs — optional; fine to push directly while it's effectively a
      solo/small-team branch, switch on when the team grows
- Force pushes / deletions: OFF

## Note on the CI trigger

`.github/workflows/ci.yml` runs on `pull_request` (any base) and on `push` to
the branches it lists. Direct pushes to `dev` only run CI if `dev` is in that
push list — see the workflow's `on.push.branches`. If you rely on required
status checks for `dev`, make sure a run actually gets produced for it.

## Default branch

Keep the repo default branch as **`main`**. GitHub sources the pull-request
template (`.github/PULL_REQUEST_TEMPLATE.md`) and the issue templates from the
default branch, so template changes take effect only once they reach `main`
(i.e. at the next release merge) — expected, not a bug.
