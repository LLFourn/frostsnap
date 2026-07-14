# sim-14-simctl-cli
# Move all app-sim tooling into one `simctl` CLI; stop growing the justfile

## Goal
Make `simctl` the single entrypoint for the app simulator — the interactive session, command
forwarding, AND running the driver e2e tests — invoked directly via a `./simctl` launcher.
Remove every sim-harness recipe from the shared `justfile`. After this, new sim features/tests
add a `simctl` subcommand or a `test_driver/*_drive.dart` file and NEVER touch the justfile.

## Why
The sim epic keeps bloating the project-wide justfile: it already carries 5 sim recipes
(`sim`, `sim-serve`, `sim-keygen-drive`, `sim-keygen-2of3`, `sim-multi-drive`), three of which
are near-identical `dart run test_driver/X.dart` wrappers that grow by one per e2e test. The
sim is a self-contained subsystem; its tooling shouldn't accrete in a justfile the whole
project reads. `test_driver/simctl.dart` is already a CLI (it has `serve` + command
forwarding); promoting it to THE entrypoint and folding test-running into it gives a stable,
sim-owned surface the justfile doesn't track.

## Scope / what moves — and what deliberately does NOT
- REMOVE from the justfile: `sim`, `sim-serve`, `sim-keygen-drive`, `sim-keygen-2of3`,
  `sim-multi-drive`. These ARE the accretion problem (sim-specific wrappers). KEEP
  `simulate` / `alias demo` — that is the unrelated `tools/widget_simulator` (a widget-level
  sim), not this app harness.
- KEEP `maybe-gen` / `gen` / `build-runner` in the justfile. They are NOT sim tooling — they are
  shared app-build infra: `maybe-gen` is also a dependency of `build`, `run`, `legacy-run`,
  `lint-app`, and `fix-dart`, and its body just calls the general `gen` + `build-runner`
  recipes. The sim CONSUMES this gen-ensure; it must not re-own or copy it. (Per-feature
  accretion — the thing we're fixing — is the 5 wrappers, NOT this stable shared infra, which
  does not grow when you add a sim test.)
- The removed recipes wrap `dart run test_driver/{simctl,keygen_drive,...}.dart`; `sim-serve`
  and the test recipes also depend on `maybe-gen`. NOTE: today the plain `sim` forwarder does
  NOT depend on `maybe-gen` — only launching (serve) / tests do — so the launcher must gen-ensure
  only for `serve`/`test`, never for a forwarded command to an already-running app.

## Design
A single `simctl` CLI plus a thin launcher; no app/Rust behavior changes (tooling only).

- Subcommands (extend `test_driver/simctl.dart`):
  - `serve [--count N] [--agent-owns-keyboard] [--platform d]` — the session daemon (exists).
  - `<cmd> ...` — forward one command to the running daemon (exists: tap, chain, disconnect,
    shot, down, …).
  - `test [NAME]` — run one driver test by FILE STEM, or all with no arg. Matching rule is exact
    stem → `test_driver/<stem>_drive.dart` (so `keygen` → `keygen_drive.dart`, `keygen_2of3` →
    `keygen_2of3_drive.dart`, `multi_device` → `multi_device_drive.dart`); an unknown stem
    errors listing the available stems (no fuzzy/prefix matching, so a future `foo_drive.dart`
    is discovered predictably). No NAME = run every `test_driver/*_drive.dart` in sequence with a
    pass/fail summary and a nonzero exit if any fail. REPLACES the three per-test recipes; future
    e2e tests need no recipe.
  - (reserved) `regtest up|down|status` — owned by the regtest plan; the CLI structure
    anticipates it but this plan does not build it.
- Launcher: an executable `./simctl` script at the repo root that, for `serve`/`test`, runs the
  EXISTING `just maybe-gen` first (shared gen-ensure — see below), then
  `cd frostsnapp && exec dart run test_driver/simctl.dart "$@"`. So `./simctl serve`,
  `./simctl chain`, `./simctl test keygen` — no `dart run`/`cd` typing. (Name `simctl` matches
  the dart file and is distinct from `simulate`.)
- Gen-ensure = call `just maybe-gen` (do NOT duplicate it). The launcher invokes the existing
  `just maybe-gen` for `serve`/`test` only (forwarded commands skip it, matching today's `sim`).
  This keeps ONE implementation of the API-hash canary + codegen + build_runner; depending on the
  project's task runner for SHARED build infra is fine — the accretion we're removing is the
  sim-specific recipes, not this. (The `./simctl` launcher is the single new sim entrypoint; it
  leans on `just` only for the shared codegen step, which it does not own.)

## Tasks
1. `simctl test [NAME]` subcommand in `test_driver/simctl.dart`: exact stem → `*_drive.dart`
   lookup (error + list available stems on miss); no-arg runs all driver tests with a summary +
   nonzero exit on any failure.
2. Gen-ensure WITHOUT duplication: the `./simctl` launcher runs `just maybe-gen` before
   `serve`/`test` (not on forwarded commands). Do NOT copy the canary/codegen/build_runner
   sequence into the CLI; `maybe-gen`/`gen`/`build-runner` stay in the justfile as the single
   source of truth (other non-sim consumers depend on them).
3. `./simctl` launcher script at repo root (executable; gen-ensure for serve/test + cwd + dart
   run; forward everything else straight through).
4. Remove the 5 sim recipes from the justfile (leave `simulate`/`demo` + `maybe-gen`/`gen`/
   `build-runner` + any unrelated aliases untouched).
5. Update references so nothing points at the removed recipes: grep broadly for `just sim-*` /
   `just sim ` across the repo and fix the `Run: just sim-*` header comments in
   `test_driver/*_drive.dart`, `simctl.dart`'s usage text, the
   `.clank/drafts/regtest-bitcoin-receiving.md` draft (`sim-regtest` → `./simctl regtest`), and
   any README/docs.

## Acceptance
- The justfile has NO app-sim recipes; `simulate`/`demo` (unrelated) and `maybe-gen`/`gen`/
  `build-runner` (shared infra) remain.
- `./simctl serve`, `./simctl <cmd>`, and `./simctl test [name]` cover everything the removed
  recipes did. Bindings auto-(re)generate on `serve`/`test` via `just maybe-gen` — no manual
  `just gen` first — and gen-ensure exists in exactly ONE place (no duplicated canary logic).
- The three driver e2e tests run via `./simctl test …` and pass (`keygen`, `keygen_2of3`,
  `multi_device`).
- No dangling `just sim-*` references in code/comments/docs (verified by grep).
- Tooling-only: no change to app/Rust behavior; esp/embedded untouched.
- Durable win demonstrated: adding a hypothetical new e2e test or session command requires
  zero justfile edits.

## Depends on
sim-5..sim-13 (the harness, `simctl serve` + the device-socket command channel, the driver
tests). Should land BEFORE the regtest feature so that work adds `./simctl regtest …` rather
than a new recipe.
