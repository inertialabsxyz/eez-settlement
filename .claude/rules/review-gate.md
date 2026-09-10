# Review Gate

After completing a feature or bug fix — before opening a PR — the implementation agent **must** spawn
a review agent to verify the work against the source requirements. This is a hard gate, equivalent to
`forge test`.

The requirements source is always `planning/settlement-spec.md`. It is the design of record: its
appendices A–E contain reference implementations of all five contracts, and `src/` is those
appendices extracted verbatim. So the review is a two-way check — the implementation must match the
spec, *and* the spec must still describe the implementation.

## When to trigger

Spawn the review agent once:
- All implementation commits are done
- `forge test` passes on the current branch
- You are about to open the PR

## How to spawn the review agent

Call the `Agent` tool with a prompt that includes:
1. The spec section (and appendix, if the change touched a contract) that specifies the requirements
2. The files that were changed
3. A one-sentence summary of what was implemented
4. The invariant numbers the change touches

**Template:**

```
Agent({
  description: "Requirements review: <feature name>",
  prompt: """
You are a review agent for eez-settlement. Your job is to verify a completed
implementation against its source requirements, fix any gaps, and commit the fixes.

## What was implemented
<one-sentence summary of the feature/fix>

## Requirements source
Read the requirements from: planning/settlement-spec.md, section "<§N — Section Name>"
<and, if a contract changed: and Appendix <X> — `<Contract>`>

## Invariants touched
<e.g. I9, I10 — cite the numbers from §10>

## Files changed
<list the changed files, e.g. src/Executor.sol, test/Properties.t.sol>

## Your task
1. Read the requirements section, and §10 for each invariant listed above
2. Read each changed file
3. For every requirement in that section, verify it is fully implemented
4. Verify each cited invariant is enforced where §10 says it is enforced (L1, L2,
   or review-only), and that the enforcing line names it in a code comment
5. Verify the spec still describes the code. If code and spec disagree, that is a
   defect in one of them, not a thing to work around: decide which is wrong, fix
   that one, and say in your report which you changed
6. For any gap found: fix it, then run `forge test` to confirm it passes
7. If you made any fixes, commit each one with: fix(scope): <description>
   Scopes: book, executor, relayer, registry, types, spec, test

## Constraints
- Do not refactor, rename, or improve code beyond what the requirements specify.
- Do not add features that are not in the requirements section.
- Do not add runtime assertions for I16, I18 or I19 — §10 states these are review
  obligations, not runtime checks, and are deliberately unenforceable in-contract.
- Do not resolve §13.2 (windfallRecipient's address) or §13.3 (COMMIT_WINDOW and
  batching cadence) by picking a value. If the change depends on either, flag it
  and stop.
- Do not add `receive()` to `Executor`. Its absence is what makes the ETH-leak
  check trivially true.
- If `forge test` fails after your fix, diagnose and resolve before committing.

## Your output

Return a structured markdown report using exactly this format:

### Requirements Checked
- <requirement 1> — PASS / FAIL / FIXED
- <requirement 2> — PASS / FAIL / FIXED
...

### Invariants Checked
- I<n> — enforced at <L1 / L2 / review>, cited in <file:line> — PASS / FAIL / FIXED

### Spec/Code Divergence
<what disagreed and which side you changed, or "None">

### Gaps Found
<bullet list of gaps, or "None">

### Fixes Made
<bullet list of commits made, each with message and one-line description, or "None">

### Quality Gate
`forge test`: PASS / FAIL
`forge fmt --check`: PASS / FAIL
"""
})
```

Capture the review agent's returned report — you will need it for the PR comment.

## What the review agent checks

- Every requirement in the spec section is present in the implementation
- Structs and storage layouts defined in §5.1 exist with the correct fields and slot counts
  (`forge inspect src/Book.sol:Book storage-layout`)
- Functions named in the spec are implemented in the correct contract
- Every invariant the change touches is enforced where §10 says it is, and cited in a comment
- Tests required by the change exist and pass; every new behaviour has at least one test, and every
  bug fix has a regression test that would have caught it
- No spec-required behaviour is silently skipped or stubbed
- `SafeERC20` is used for every token call — the design is worthless if it cannot settle USDT
- Custom errors, not revert strings, with an index parameter where a loop can fail on one element
- Gas figures quoted in §11 are labelled **measured** or **estimated**

The review agent does **not** open the PR. Once it reports back, proceed to open the draft PR.
