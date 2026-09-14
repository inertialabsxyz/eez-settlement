# Commits

**Gate:** `forge test` must pass before every commit. No exceptions. See `.claude/rules/testing.md`
for why `forge build` is not a substitute.

**Auto-commit:** Commit each logical change as it is completed, without waiting to be asked. Use
judgment to determine when a change is coherent and complete — do not commit mid-feature or bundle
unrelated changes.

**Message format:** `type(scope): short description`

- `type` — `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
- `scope` — the contract or area:
  - Contracts: `book`, `executor`, `relayer`, `registry`, `types`
  - Cross-cutting: `spec`, `test`, `repo`, `ci`, `planning`
- Description — imperative, lowercase, no period. 72 characters total max.

```
feat(book): freeze the candidate set at the commit deadline
fix(executor): compare exit balance for equality, not >=
refactor(relayer): move the digest re-derivation into pullBatch
test(properties): add I12 case for an interaction targeting Relayer
docs(spec): mark §13.2 windfallRecipient as still blocking
```

**Scope:** One logical change per commit. Don't bundle unrelated fixes.

**Spec and code still move together, across two repositories.** The design of record is
`settlement-spec.md` in `github.com/inertialabsxyz/eez-settlement-planning`, and `src/` is its
appendices extracted verbatim. They can no longer be committed atomically, which makes the
obligation easier to drop and no less real: a change to one that should have changed the other is
still incomplete work.

So when a change needs both, the commit message here names the spec commit — or says plainly that
the spec change is outstanding and why. A PR that changed `src/` without saying what happened to the
appendix should not be approved. Never edit the spec to match code you have just written.

**Two things you may not commit a resolution for.** §13.2 (`windfallRecipient`'s address) and §13.3
(`COMMIT_WINDOW` and batching cadence) are open questions that block implementation. Flag them and
stop; do not pick a value and commit it.
