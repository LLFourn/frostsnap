# fsim-change-index-repro
# fsim-change-index-repro — land the change-index repro as a real test, red here and green on master

## Why

`9c543ac` ("[send-plan-refactor] fsim repro: first send's change must use the first
change address") reproduced a real bug: `TxState::fee()` ran the full `send_to`
(reveal + mark-used) on every rebuild of the signer-selection page, so the first
send's change landed at internal index >= 1 and the gap grew with every repaint.

That repro was ported onto this stack's `faucet.rpc` passthrough while validating
`fsim-faucet-rpc-passthrough` — deriving the expected change address entirely
through bitcoind RPC, with zero fsim library edits, which was that plan's whole
acceptance criterion. It has been sitting untracked ever since, which is a poor
home for a test worth keeping.

It is worth keeping because it is an EXPERIMENT with a known answer at both ends:

- on this stack's base it FAILS (the fee path still burns change indices),
- on current `origin/master` it should PASS — `f15560fe [coord,app] Make the fee
  display pure` and `d8d126bc [change-reservations] Change reservations are a
  computed view of live signing sessions, not wallet state` are exactly the fix,
  merged via `e5bbdde7` (PR #542).

So landing it turns the restack into a verification: if it flips red -> green with
no edits, the test, the fix, and the restack all confirm each other. If it stays
red after the restack, the fix is incomplete and we learn that at the point where
it is cheapest to act on.

## The awkward part, stated plainly

Committing a known-red test makes `fsim test` report a failure until this stack is
restacked. A suite that is expected-red is a suite whose signal people stop
reading, and this one is red for a reason unrelated to whatever a future change
breaks. The plan therefore lands the test AND the runner support that keeps the
overall signal honest, rather than asking everyone to remember which failure is
"the expected one".

The danger in that support is over-reach: a marker that excuses the whole scenario
would hide real regressions behind an expected one. The model below is built to
make that impossible.

## Model

A test carries its expectation, and the expectation is scoped to ONE ASSERTION —
never to the scenario. That distinction is the whole design. This repro launches
the app, runs a keygen, funds a wallet, navigates the UI, signs on-device,
broadcasts, mines, and waits on electrs before it ever reaches the change-index
assertion. A scenario-wide "expected to fail" marker would report a startup crash,
a UI regression, a backend outage, or a wedged run as `xfail` with exit 0 — hiding
precisely the regressions the suite exists to catch. This is not hypothetical: a
parallel run of the current suite failed `erase_device` on a modal-barrier tap and
`backup_restore` on an ambiguous finder, and a scenario-wide marker on this test
would absorb that entire class of failure silently.

So the contract is a protocol between the test and the runner, with both halves
living in the test file:

- The test DECLARES its expectation up front, naming the fix that should retire it.
- Around the designated assertion ONLY, it catches that assertion's specific
  failure identity, emits the expected-failure marker, and exits successfully.
  The catch is narrow by construction: one assertion, one identity — anything else
  propagates and fails the run normally.

The runner classifies on what it actually observed:

| observed | verdict | counts as |
|---|---|---|
| timed out | `TIMEOUT` | failure |
| nonzero exit (anything unrelated) | `FAILED` | failure |
| exit 0, declared, designated assertion failed (marker present) | `XFAIL` | not a failure |
| exit 0, declared, marker ABSENT (the assertion passed, or the terminal outcome never arrived) | `XPASS` | HARD failure |

The last row is what stops quarantine becoming a graveyard: an expected-fail test
can only break the build by starting to pass — exactly when a human should look at
it and delete the marker. It is also why a missing marker must be a failure rather
than a pass: "the run ended without reaching its own conclusion" is indistinguishable
from success otherwise.

## Milestone 1 — expected-fail scoped to an assertion

- The declaration + marker protocol above, implemented in the harness so a test
  expresses it in one place (declaration naming the fix ref; a guarded assertion
  helper that emits the marker and exits 0 when the designated assertion fails).
- `fsim test` classifies per the table and reports `xfail` / `xpass` distinctly from
  `ok` / `FAILED` / `TIMEOUT`, in the summary and in `--junit` (`xfail` maps to
  `skipped` with its message; `xpass` and unrelated failures map to `failure`).
- Unit coverage for EVERY row of the table, not just expected-vs-actual pass/fail:
  an unrelated nonzero exit under a declared expectation must be `FAILED`, a
  timeout must be `TIMEOUT`, and a declared expectation with no marker must be a
  hard `XPASS`.
- `COMMANDS.md` documents the protocol and when to remove a marker.

## Milestone 2 — land the repro

- Commit `regtest_change_first_drive.dart` from `stash@{0}` (200 lines; the port
  already validated against the rpc passthrough), declaring the expectation with
  `f15560fe` as the fix that should retire it, and guarding ONLY the final
  change-index assertion.
- Confirm the run reports `xfail` and the suite exit stays 0, and that breaking any
  earlier step (e.g. an injected navigation failure) still reports `FAILED`.
- Record the restack experiment: rebase onto `origin/master`, run
  `./fsim test regtest_change_first`, expect `XPASS` — then delete the marker in
  that same commit.

## Non-goals

- Fixing the change-index bug here (it is already fixed on master).
- A general skip/ignore mechanism. Expected-fail is not "ignore this": a test that
  is merely flaky or unfinished does not belong in the suite at all.
- Retroactively marking any other currently-failing test. If the suite has other
  failures they are bugs to fix, not expectations to record.
