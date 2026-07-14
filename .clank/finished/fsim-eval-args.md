# fsim-eval-args
# fsim-eval-args — sanitized `--arg` passing for eval + two residues

Replaces the rejected daemon-side `var a` rewrite (never landed) with SANITIZED argument passing, plus the two
small residue cleanups the `fsim-eval-unified-drive` post-finalize audit named.

## Goal
`fsim eval --arg name=value` (`-a name=value`, repeatable) binds `name` in the snippet's scope from a
shell-held value — NO preparser, NO rewrite/parse of the user's snippet, NO daemon-global var store. Binding is
pure VM-protocol (the `scope` parameter), spike-confirmed to reach the fired snippet. The shell holds the vars
(`addr=$(fsim eval "…")`) and `-a` threads them in. This is the clean form of "capture a value in one eval, use
it in the next": the state lives in the shell, not a global scratch in the daemon; the daemon stays stateless
except for the genuinely-live `session`/`instances`.

## Task 1 — `fsim eval -a/--arg name=value` (scope-only binding, no preparser)
`fsim eval -a name=value [-a n2=v2 …] "<snippet>"` binds each `name` in the snippet's scope from `value`. The
user's snippet AND the fire-wrapper source are UNCHANGED — nothing is parsed or spliced. Binding is pure
VM-protocol, three parts:

- **Materialize the value** as a String OBJECT in the isolate via a helper `evaluate` that builds it from its
  BYTES — `utf8.decode(base64.decode('<b64>'))` (or `String.fromCharCodes([…])`). base64/int-list can't inject,
  so the value TEXT never appears in any evaluated source. Grab the resulting `InstanceRef.id`.
- **Bind via evaluate's `scope` parameter**: pass `scope: {name: <value-id>, …}` to the EXISTING fire
  `evaluate`. SPIKE-CONFIRMED (against a live daemon) that a `scope` var reaches a snippet nested inside sync
  closures AND the async fire IIFE: `x`→`hi`, `(() => x + "!")()`→`hi!`, `(() { return (() => x)(); })()`→`hi`,
  and the async-IIFE fire shape referencing `x` runs (returns its Future) instead of erroring. So there is NO
  prelude and NO fallback — the fire wrapper is untouched.
- **Reserve the internal namespace so a bound arg can't collide with a generated local.** With scope-binding a
  wrapper local named `g` would SHADOW a scope-injected `g`, silently dropping the arg — same class of bug as
  source collision. So: rename EVERY generated fire-wrapper local to an `_fsimEval*` prefix (e.g.
  `_fsimEvalGen`, `_fsimEvalRes`), and REJECT any `--arg` name that is not a LETTER-initial Dart identifier
  (`^[a-zA-Z]\w*$` — no leading `_`, reserving the entire `_`-namespace for internals), is a Dart keyword, or
  is a top-level console/eval name it would shadow (`session`, `instances`,
  `evalResult`/`evalError`/`evalDone`/`evalGen`/`evalCapture`). An invalid name is a CLEAR CLI error before
  anything is evaluated. Arg names and internal names now live in DISJOINT namespaces — no source injection
  (nothing spliced) and no wrapper-local shadowing.

Values are Strings; a snippet needing a non-string parses it (`int.parse(name)`). Keep the eval timeout +
gen-guard. Docs (`test_driver/COMMANDS.md`, `fsim eval --help`/`_evalHelp`, the `_usage` eval line) show the
capture→pass idiom and that `-a` values are strings.
- **Acceptance:** `fsim up`; `fsim eval -a x=hello "x + ' world'"` → `hello world`; `fsim eval -a a=3 -a b=4
  "int.parse(a) + int.parse(b)"` → `7`; an INJECTION-y VALUE binds literally, not as code — `fsim eval -a
  's=a$b";x' "s"` prints exactly `a$b";x` (no interpolation, no code run); an INVALID/RESERVED NAME is REJECTED
  before eval with a clear error, daemon untouched — each of `fsim eval -a '1);evil(=1' "1"` (not an
  identifier), `-a 'var=1' "1"` (keyword), `-a 'session=1' "1"` (reserved console name), and `-a '_g=1' "1"` /
  `-a '_fsimEvalGen=1' "1"` (leading-underscore / internal namespace) exits non-zero; plain `fsim eval "1+1"`
  (no `-a`) still works; the eval timeout + gen-guard still hold; docs show the `addr=$(fsim eval …); fsim eval
  -a addr="$addr" "…fund(addr, …)…"` idiom.

## Task 2 — remove the `harness` leftover + unify the host regtest defines
(Audit residues from `fsim-eval-unified-drive`; codex confirmed both are real.)
- `harness` in `_serve` (`fsim.dart`, `harness = launched.first`) is now just `instances.first`, kept only to
  feed `_dispatch` — a pre-multi-instance leftover. Pass `instances.first` to `_dispatch` and delete the
  `late final AppSession harness` field.
- The `SIM_REGTEST_*` HOST defines are built in two places — the serve (`fsim.dart`, ~`SIM_REGTEST_ELECTRUM_URL
  = rtSession.url`) and `_startChain`/`_ScenarioRegtest` (`sim_harness.dart`) — both mapping a `RegtestSession`
  → `{SIM_REGTEST_ELECTRUM_URL: url, SIM_REGTEST_CONTROL_SOCKET: controlSocket}`. Extract ONE helper (e.g. a
  `hostDefines` getter on `RegtestSession`) that both call. (Android bridging stays per-path — serve = dynamic
  adb-reverse proxy, tests = the shared APK's fixed baked ports — a genuine build-once-APK constraint.)
- **Acceptance:** no `harness` field in `_serve`; the host `SIM_REGTEST_*` mapping exists in ONE place, called
  by both serve + `_startChain`; `./fsim test keygen regtest_receive regtest_dual_send` green; `fsim up` +
  `fsim eval "(await session.faucet()).blockHeight()"` still works; analyze + format clean.

## Notes
- A stateful REPL that holds vars CLIENT-side (in the repl process) and re-injects them via the same `-a`
  mechanism is a possible follow-up — out of scope here; the repl stays line-at-a-time (session/app state
  still persists across lines).
- Out of scope (constraint-driven): the android bridge asymmetry (above) and the session root scheme
  (`rt-<pid>` vs `<dir>/.fsim`, socket-length).
