/// How a scenario process's exit is turned into a verdict — the one place that decides what
/// "the suite is green" means. Kept dependency-free so it is unit-testable without launching
/// anything (`test/test_outcome_test.dart` covers every row of the table below).
library;

/// A scenario prints this (then exits 0) to declare itself SKIPPED — e.g. a host-only
/// dual-instance scenario running on an emulator.
const simTestSkippedMarker = 'SIM_TEST_SKIPPED';

/// A scenario prints this to declare that ONE designated assertion is expected to fail
/// (see `ExpectedFailure` in sim_harness.dart).
const simTestExpectedFailDeclaredMarker = 'SIM_TEST_XFAIL_DECLARED';

/// A scenario prints this when that designated assertion actually failed. Deliberately not a
/// prefix-extension of the declaration marker, so neither can be mistaken for the other.
const simTestExpectedFailHitMarker = 'SIM_TEST_XFAIL_HIT';

/// The verdict for one scenario process.
///
/// | observed | verdict |
/// |---|---|
/// | timed out | `TIMEOUT` |
/// | nonzero exit — anything unrelated | `FAILED` |
/// | exit 0, skip marker | `SKIPPED` |
/// | exit 0, expectation declared AND its assertion failed | `XFAIL` |
/// | exit 0, expectation declared, marker absent | `XPASS` |
/// | exit 0 otherwise | `PASSED` |
///
/// The two rules that carry the weight: an expectation excuses only its own assertion — any
/// other failure still exits nonzero and lands as `FAILED` — and a declared expectation whose
/// marker never arrives is `XPASS`, a HARD failure, because the assertion passing and the run
/// never reaching it are both reasons to stop expecting failure.
String classifyRun({
  required bool timedOut,
  required int exitCode,
  required String output,
}) {
  if (timedOut) return 'TIMEOUT';
  if (exitCode != 0) return 'FAILED';
  if (output.contains(simTestSkippedMarker)) return 'SKIPPED';
  if (output.contains(simTestExpectedFailDeclaredMarker)) {
    return output.contains(simTestExpectedFailHitMarker) ? 'XFAIL' : 'XPASS';
  }
  return 'PASSED';
}

/// Whether [status] counts against the run. `XFAIL` is reported but does not fail the suite;
/// `XPASS` does, and so does everything else that is not a pass or a skip.
bool statusIsFailure(String status) =>
    status != 'PASSED' && status != 'SKIPPED' && status != 'XFAIL';
