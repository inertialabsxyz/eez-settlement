# Pull Requests

When all commits on a branch are done, `forge test` passes, and the review agent has reported back,
push and open a PR automatically.

There is no separate pre-PR gate — `forge test` is the whole gate. CI
(`.github/workflows/test.yml`) additionally runs `forge fmt --check` and `forge build --sizes` on
every push, so run both locally before pushing rather than discovering them red on the PR.

`forge fmt --check` does not pass repo-wide today (see `.claude/rules/testing.md`), so CI is red on
formatting independently of any branch. Check the files your branch touched — `forge fmt --check
<paths>` — and say in the PR body that the repo-wide failure is pre-existing. Do not reformat `src/`
to go green without reformatting the matching spec appendices in the same commit.

- **Target:** always `main`
- **State:** always open as **draft**
- **Branch:** `type/short-name`
- **Title:** `type(scope): short description` — same convention as the commit that drove the work
  (see `.claude/rules/commits.md`)
- **Body:** summarise what changed (bullet points from the commits) and reference the spec section it
  implements or corrects (e.g. _Implements §9.1 — why the residue must not go to the solver,
  `planning/settlement-spec.md`_)

```bash
git push -u origin <branch>
gh pr create --draft --base main --title "..." --body "..."
```

## What the body must state

- **Which invariants the change touches**, by number, and where each is now enforced.
- **Any spec/code divergence** the work resolved, and which side was changed. The spec is the design
  of record; a PR that changed it must say so explicitly.
- **Gas**, if the change moves any figure in §11 — labelled **measured** or **estimated**, with the
  `forge test` gas output for the measured ones.
- **Any §13 open question the work ran into.** §13.2 (`windfallRecipient`) and §13.3
  (`COMMIT_WINDOW`, batching cadence) block implementation and must not be resolved by picking a
  value. If the branch worked around either, say how.

## Agent Run Report (PR comment)

Immediately after the PR is created, post an agent run report as a PR comment. Assemble it from:
1. `git log main..HEAD --oneline` — the implementation commits
2. The review agent's returned report (captured earlier)

```bash
gh pr comment <PR-number> --body "$(cat <<'REPORT'
## Agent Run Report

### Implementation Commits
- <commit hash> <commit message>
- ...

### Review Report
<paste the review agent's full structured output here>
REPORT
)"
```

This comment is the permanent record of what every agent did on this branch. It must be posted before
the branch is considered done.
