# fsim-eval-full-strings

`fsim eval` / `fsim repl` print a snippet's result and error via `InstanceRef.valueAsString`, which the VM
service truncates to a ~128-char preview for long strings. `fsim eval "session.semantics().json()"` yields
129 bytes of malformed JSON; a long exception+stacktrace is clipped the same way. Fetch the FULL string.

## Why

`_evalOnce` reads the result with `service.evaluate(..., 'evalResult.toString()')` and prints
`res.valueAsString` (`fsim.dart:439-446`); the error path prints `err.valueAsString` (`:433-435`). For a
String instance the VM service caps `valueAsString` and sets `valueAsStringIsTruncated: true` — we never
check it, so anything long (a semantics tree, an address list, a stack trace) is silently corrupted at the
printer. This defeats the whole point of `session.semantics().json()` (fsim-eval-semantics): the tree can't
be piped to a file and machine-parsed. The full value is retrievable by paging `getObject` with
`offset`/`count`; only the client needs to change.

## Scope — `frostsnapp/test_driver/fsim.dart` + `frostsnapp/test/` (one commit, tree green)

- ADD a pure paging helper (new `test_driver/eval_strings.dart` or similar, so it's unit-testable without a
  live VM): `assembleFullString(String? preview, bool truncated, int? length, fetch)` where
  `fetch(offset, count)` returns the next chunk — not truncated → return the preview as-is; truncated →
  concatenate chunks (e.g. 64k) from the preview's end until `length` chars are collected.
- ADD a thin VM-service adapter in `fsim.dart`: given the `InstanceRef`, wire `fetch` to
  `service.getObject(isolateId, ref.id!, offset: o, count: c)` and read the returned `Instance.valueAsString`.
- Use it for BOTH reads in `_evalOnce`: the result print (`:439-446`) and the error print (`:433-435`).
  Preserve the existing null handling (`?? '<${classRef?.name}>'`). The repl shares `_evalOnce`, so it's
  fixed for free. The `evalDone` poll (`:422`, short literal) stays as-is.

### Tests — `frostsnapp/test/eval_strings_test.dart`

- not truncated → preview returned verbatim, `fetch` never called.
- truncated → chunks requested in order with correct offsets, result exactly `length` chars, matches the
  reassembled source string.
- truncated with a `fetch` that returns short/empty chunk → loud error, no infinite loop.

## Acceptance

- `fsim eval "List.filled(500000, 'x').join()"` → exactly 500000 `x`s (plus trailing newline).
- Live session: `fsim eval "session.semantics().json()" > tree.json` → `jq . tree.json` parses; the tree
  contains the full node set (spot-check a known deep label).
- Error path: `fsim eval "throw StateError(List.filled(10000, 'y').join())"` → the full 10000-char message
  on stderr.
- `flutter test test/eval_strings_test.dart` green; `dart analyze test_driver` clean.
